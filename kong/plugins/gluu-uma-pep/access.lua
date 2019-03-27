local pl_tablex = require "pl.tablex"
local oxd = require "gluu.oxdweb"
local resty_session = require("resty.session")

local kong_auth_pep_common = require"gluu.kong-auth-pep-common"

local unexpected_error = kong_auth_pep_common.unexpected_error

-- call /uma-rs-check-access oxd API, handle errors
local function try_check_access(conf, path, method, token, access_token)
    token = token or ""
    local response = oxd.uma_rs_check_access(conf.oxd_url,
        {
            oxd_id = conf.oxd_id,
            rpt = token,
            path = path,
            http_method = method,
        },
        access_token)
    local status = response.status
    if status == 200 then
        -- TODO check status and ticket
        local body = response.body
        if not body.access then
            return unexpected_error("uma_rs_check_access() missed access")
        end
        if body.access == "granted" then
            return body
        elseif body.access == "denied" then
            if token == "" and not body["www-authenticate_header"] then
                return unexpected_error("uma_rs_check_access() access == denied, but missing www-authenticate_header")
            end
            kong.ctx.shared.gluu_uma_ticket = body.ticket
            return body
        end
        return unexpected_error("uma_rs_check_access() unexpected access value: ", body.access)
    end
    if status == 400 then
        return unexpected_error("uma_rs_check_access() responds with status 400 - Invalid parameters are provided to endpoint")
    elseif status == 500 then
        return unexpected_error("uma_rs_check_access() responds with status 500 - Internal error occured. Please check oxd-server.log file for details")
    elseif status == 403 then
        return unexpected_error("uma_rs_check_access() responds with status 403 - Invalid access token provided in Authorization header")
    end
    return unexpected_error("uma_rs_check_access() responds with unexpected status: ", status)
end

local hooks = {}

local function redirect_to_claim_url(conf, ticket)
    local ptoken = kong_auth_pep_common.get_protection_token(nil, conf)

    local response, err = oxd.uma_rp_get_claims_gathering_url(conf.oxd_url,
        {
            oxd_id = conf.oxd_id,
            ticket = ticket
        },
        ptoken)

    if err then
        kong.log.err(err)
        return unexpected_error()
    end

    local status, json = response.status, response.body

    if status ~= 200 then
        kong.log.err("uma_rp_get_claims_gathering_url() responds with status ", status)
        return unexpected_error()
    end

    if not json.url then
        kong.log.err("uma_rp_get_claims_gathering_url() missed url")
        return unexpected_error()
    end

    local session = resty_session.start()
    local session_data = session.data
    -- by uma_original_url session's field we distinguish enduser session previously redirected
    -- to OP for authorization
    session_data.uma_original_url = ngx.var.request_uri
    session:save()

    -- redirect to the /uma/gather_claims url endpoint
    ngx.header["Cache-Control"] = "no-cache, no-store, max-age=0"
    ngx.redirect(json.url)
end

-- call /uma_rp_get_rpt oxd API, handle errors
local function get_rpt_by_ticket(self, conf, ticket, state, pct_token)
    local ptoken = kong_auth_pep_common.get_protection_token(self, conf)

    local requestBody = {
        oxd_id = conf.oxd_id,
        ticket = ticket
    }

    if state then
        requestBody.state = state
    end

    if conf.pct_id_token_jwt then
        requestBody.claim_token = pct_token
        requestBody.claim_token_format = "https://openid.net/specs/openid-connect-core-1_0.html#IDToken"
    end

    local response = oxd.uma_rp_get_rpt(conf.oxd_url,
        requestBody,
        ptoken)
    local status = response.status
    local body = response.body

    if status ~= 200 then
        if conf.redirect_claim_gathering_url and status == 403 and body.error and body.error == "need_info" then
            kong.log.debug("Starting claim gathering flow")
            redirect_to_claim_url(conf, ticket)
        end

        return unexpected_error("Failed to get RPT token")
    end

    return body.access_token
end

--- lookup registered protected path by path and http methods
-- @param self: Kong plugin object instance
-- @param conf:
-- @param exp: OAuth scope expression Example: [{ path: "/posts", ...}, { path: "/todos", ...}] it must be sorted - longest strings first
-- @param request_path: requested api endpoint(path) Example: "/posts/one/two"
-- @param method: requested http method Example: GET
-- @return protected_path; may returns no values
function hooks.get_path_by_request_path_method(self, conf, request_path, method)
    local exp = conf.uma_scope_expression
    -- TODO the complexity is O(N), think how to optimize
    local found_paths = {}
    print(request_path)
    for i = 1, #exp do
        print(exp[i]["path"])
        if kong_auth_pep_common.is_path_match(request_path, exp[i]["path"]) then
            print(exp[i]["path"])
            found_paths[#found_paths + 1] = exp[i]
        end
    end

    for i = 1, #found_paths do
        local path_item = found_paths[i]
        kong.log.inspect(path_item)
        for k = 1, #path_item.conditions do
            local rule = path_item.conditions[k]
            kong.log.inspect(rule)
            if pl_tablex.find(rule.httpMethods, method) then
                return path_item.path
            end
        end
    end

    return nil
end

function hooks.no_token_protected_path(self, conf, protected_path, method)
    local ptoken = kong_auth_pep_common.get_protection_token(self, conf)

    local check_access_no_rpt_response = try_check_access(conf, protected_path, method, nil, ptoken)

    if check_access_no_rpt_response.access == "denied" then
        kong.log.debug("Set WWW-Authenticate header with ticket")
        return kong.response.exit(401,
            { message = "Unauthorized" },
            { ["WWW-Authenticate"] = check_access_no_rpt_response["www-authenticate_header"]}
        )
    end
    return unexpected_error("check_access without RPT token, responds with access == \"granted\"")
end

local function get_ticket(self, conf, protected_path, method)
    local ptoken = kong_auth_pep_common.get_protection_token(self, conf)

    local check_access_no_rpt_response = try_check_access(conf, protected_path, method, nil, ptoken)

    if check_access_no_rpt_response.access == "denied" and check_access_no_rpt_response.ticket then
        return check_access_no_rpt_response.ticket
    end
    return unexpected_error("check_access without RPT token, responds without ticket")
end

function hooks.build_cache_key(method, path, token)
    path = path or ""
    local t = {
        method,
        ":",
        path,
        ":",
        token
    }
    return table.concat(t), true
end

function hooks.is_access_granted(self, conf, protected_path, method, scope_expression, _, rpt)
    local ptoken = kong_auth_pep_common.get_protection_token(self, conf)

    local check_access_response = try_check_access(conf, protected_path, method, rpt, ptoken)

    return check_access_response.access == "granted"
end

--- obtain_rpt
-- @return nothing, set RPT token in kong.share.context
local function obtain_rpt(self, conf)
    local authenticated_token = kong.ctx.shared.authenticated_token
    local enc_id_token, exp = authenticated_token.enc_id_token, authenticated_token.exp
    local cached_rpt = kong_auth_pep_common.worker_cache_get_pending(enc_id_token)
    if cached_rpt then
        kong.log.debug("Found rpt token in cache")
        kong.ctx.shared.request_token = cached_rpt
        return -- next steps handle by access_pep_handler
    end

    kong_auth_pep_common.set_pending_state(enc_id_token)
    local method, path  = ngx.req.get_method(), ngx.var.uri
    local protected_path, _ = hooks.get_path_by_request_path_method(self, conf, path, method)

    if not protected_path and conf.deny_by_default and path ~= conf.claims_redirect_path then
        kong_auth_pep_common.clear_pending_state(enc_id_token)
        kong.log.err("Path: ", path, " and method: ", method, " are not protected with scope expression. Configure your scope expression.")
        return kong.response.exit(403, { message = "Unprotected path/method are not allowed" })
    end

    local session
    local is_ticket_from_claim_gathering = false
    local ticket, state
    if conf.redirect_claim_gathering_url and path == conf.claims_redirect_path then
        kong.log.debug("Claim Redirect URI path (", path, ") is currently navigated -> Processing ticket response coming from OP")

        session = resty_session.start()
        if not session.present then
            kong.log.err("request to the claim redirect response path but there's no session state found")
            return kong.response.exit(400)
        end

        local args = ngx.req.get_uri_args()
        ticket, state = args.ticket, args.state
        if not ticket or not state then
            kong.log.warn("missed ticket or state argument(s)")
            return kong.response.exit(400, {message = "missed ticket or state argument(s)"})
        end
        is_ticket_from_claim_gathering = true
        ticket = args.ticket
    else
        ticket = get_ticket(self, conf, protected_path, method)
    end

    local rpt = get_rpt_by_ticket(self, conf, ticket, state, enc_id_token)
    kong.ctx.shared.request_token = rpt
    kong_auth_pep_common.worker_cache:set(enc_id_token, rpt, exp - ngx.now() - kong_auth_pep_common.EXPIRE_DELTA)

    if is_ticket_from_claim_gathering then
        local session_data = session.data
        local uma_original_url = session_data.uma_original_url
        -- redirect to the URL that was accessed originally
        kong.log.debug("Got RPT and Claim flow completed -> Redirecting to original URL (", uma_original_url, ")")
        ngx.redirect(uma_original_url)
    end
    -- next steps handle by access_pep_handler
end

return function(self, conf)
    if conf.obtain_rpt then
        obtain_rpt(self, conf)
    end

    -- check is_access_granted
    kong_auth_pep_common.access_pep_handler(self, conf, hooks)
end
