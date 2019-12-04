local BasePlugin = require "kong.plugins.base_plugin"
local utils = require "kong.tools.utils"
local lrucache = require "resty.lrucache"
local http = require "resty.http"
local url = require "socket.url"
local cjson   = require "cjson"

local kong = kong
local cache, _ = lrucache.new(200)

local TokenIntrospectionPlugin = BasePlugin:extend()

TokenIntrospectionPlugin.VERSION  = "0.0.1"
TokenIntrospectionPlugin.PRIORITY = 1010

function TokenIntrospectionPlugin:new()
    TokenIntrospectionPlugin.super.new(self, "token-introspection")
end

-- access_token : String
--              : Consumer|nil
local function get_cached_consumer(access_token)
    local consumer, _, _ = cache:get(access_token)
    return consumer
end

-- access_token : String
-- consumer     : Table { client_id: String, username: String }
-- ttl          : Number - in seconds
--              : Unit
local function cache_consumer(access_token, consumer, ttl)
    cache:set(access_token, consumer, ttl)
end

-- req  : kong.request
--      : String|nil
local function fetch_access_token(req)
    local headers = req.get_headers()
    local headerOpt = headers["Authorization"]
    if headerOpt then
        local splited = utils.split(headerOpt, " ")
        if splited[2] then
            return splited[2]
        end
    end
    return nil;
end


local parsed_url = nil
-- url_string   : String
--              : Table { host: String, port: Number }
local function parse_url(url_string)
    if parsed_url then
        return parsed_url
    end

    parsed_url = url.parse(url_string)
    if not parsed_url.port then
        if parsed_url.scheme == "http" then
            parsed_url.port = 80
        elseif parsed_url.scheme == "https" then
            parsed_url.port = 443
        end
    end
    return parsed_url
end

-- access_token : String
-- url_string   : String
--              : String|nil
local function make_http_request(access_token, url_string)
    local httpc = http.new()
    httpc:set_timeout(1000)
    local url_obj = parse_url(url_string)
    local host = url_obj.host
    local port = url_obj.port
    local ok, err = httpc:connect(host, port)
    if not ok then
        kong.log.err("failed to connect to " .. host .. ":" .. tostring(port) .. ": " .. err)
        return nil
    end

    if parsed_url.scheme == "https" then
        local _, err = httpc:ssl_handshake(true, host, false)
        if err then
            kong.log.err("failed to do SSL handshake with " .. host .. ":" .. tostring(port) .. ": " .. err)
            return nil
        end
    end

    local res, err = httpc:request({
        method = "POST",
        path = parsed_url.path or "/",
        query = parsed_url.query,
        headers = {
            ["Host"] = parsed_url.host,
            ["Content-Type"] = "application/x-www-form-urlencoded"
        },
        body = "token=" .. access_token,
    })
    if not res then
        kong.log.err("failed request to " .. host .. ":" .. tostring(port) .. ": " .. err)
        return nil
    end

    local response_body = res:read_body()
    if res.status ~= 200 then
        kong.log.err("request to " .. host .. ":" .. tostring(port) ..
                     " returned status code " .. tostring(res.status) .. " and body " ..
                     response_body)
    end
    return response_body
end

-- rep  : String
--      : String|nil
local function read_response(rep_body)
    local serialized_content, err = cjson.decode(rep_body)
    if not serialized_content then
        kong.log.err("Serialization error: ", err)
        return nil
    end

    return serialized_content["client_id"]
end

-- access_token : String
-- url          : String
--              : String|nil
local function request_introspection_server(access_token, url)
    local rep_body = make_http_request(access_token, url)
    if rep_body then
        return read_response(rep_body)
    end
    return nil
end

-- client_id    : String|nil
--              : Consumer|nil
local function query_consumer(client_id)
    local consumer, err = kong.db.consumers:select_by_custom_id(client_id)
    kong.log("fetching consumer: ", consumer)
    if err then
        kong.log.err("Can't fetch consumer: ", err)
        return nil
    end
    return consumer
end


function TokenIntrospectionPlugin:access(conf)
    TokenIntrospectionPlugin.super.access(self)

    local access_token = fetch_access_token(kong.request)
    if not access_token and not conf.allow_anonymous then
        return kong.response.exit(401, {
            message = "Provide Authorization header"
        })
    end

    if access_token then
        local consumer = get_cached_consumer(access_token)
        if not consumer then
            local client_id = request_introspection_server(access_token, conf.endpoint)
            if client_id then
                consumer = query_consumer(client_id)
                cache_consumer(access_token, consumer, conf.cache_ttl)
            end
        end
        -- stil don't have a consumer
        if not consumer then
            return kong.response.exit(401, {
                message = "Provided access_token is invalid"
            })
        end
        kong.client.authenticate(consumer, nil)
    end
end

return TokenIntrospectionPlugin