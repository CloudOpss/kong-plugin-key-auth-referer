local cache = require "kong.tools.database_cache"
local auth_cache = require "kong.plugins.key-auth-referer.cache"
local responses = require "kong.tools.responses"
local constants = require "kong.constants"
local singletons = require "kong.singletons"
local public_tools = require "kong.tools.public"
local BasePlugin = require "kong.plugins.base_plugin"

local ngx_set_header = ngx.req.set_header
local ngx_get_headers = ngx.req.get_headers
local set_uri_args = ngx.req.set_uri_args
local get_uri_args = ngx.req.get_uri_args
local clear_header = ngx.req.clear_header
local ngx_req_read_body = ngx.req.read_body
local ngx_req_set_body_data = ngx.req.set_body_data
local ngx_encode_args = ngx.encode_args
local type = type

local _realm = 'Key realm="'.._KONG._NAME..'"'

local KeyAuthHandlerReferer = BasePlugin:extend()

KeyAuthHandlerReferer.PRIORITY = 1000

function KeyAuthHandlerReferer:new()
  KeyAuthHandlerReferer.super.new(self, "key-auth-referer")
end

local function load_credential(key)
  local creds, err = singletons.dao.keyauthreferer_credentials:find_all {
    key = key
  }
  if not creds then
    return nil, err
  end
  return creds[1]
end

local function load_consumer(consumer_id, anonymous)
  local result, err = singletons.dao.consumers:find { id = consumer_id }
  if not result then
    if anonymous and not err then
      err = 'anonymous consumer "'..consumer_id..'" not found'
    end
    return nil, err
  end
  return result
end

local function set_consumer(consumer, credential)
  ngx_set_header(constants.HEADERS.CONSUMER_ID, consumer.id)
  ngx_set_header(constants.HEADERS.CONSUMER_CUSTOM_ID, consumer.custom_id)
  ngx_set_header(constants.HEADERS.CONSUMER_USERNAME, consumer.username)
  ngx.ctx.authenticated_consumer = consumer
  if credential then
    ngx_set_header(constants.HEADERS.CREDENTIAL_USERNAME, credential.username)
    ngx.ctx.authenticated_credential = credential
    ngx_set_header(constants.HEADERS.ANONYMOUS, nil) -- in case of auth plugins concatenation
  else
    ngx_set_header(constants.HEADERS.ANONYMOUS, true)
  end
  
end

local function testReferer(refererConf, refererToTest)
  if refererConf == refererToTest then
    return true
  end

  local authorizedReferer = string.gsub(refererConf, "%.", "%%.")
  authorizedReferer = string.gsub(authorizedReferer, "*", "[^.]*")

  local test = string.match(refererToTest, authorizedReferer)
  if test == refererToTest then
    return true
  else
    return false
  end
end


local function testListReferer(listReferer, refererToTest)
  if refererToTest == "" or refererToTest == nil then
    return false
  end

  local domainRefererToTest = string.match(refererToTest, "^[https?]*[://]*([^/]+)")
  
  if domainRefererToTest == nil then
    return false
  end



  for index, valeur in ipairs(listReferer) do
    if valeur == "*" then
      return true
    end

    if testReferer(valeur, domainRefererToTest) == true then
      return true
    end
  end

  return false
end

local function do_authentication(conf)
  if type(conf.key_names) ~= "table" then
    ngx.log(ngx.ERR, "[key-auth] no conf.key_names set, aborting plugin execution")
    return false, {status = 500, message= "Invalid plugin configuration"}
  end

  local key
  local headers = ngx_get_headers()
  local uri_args = get_uri_args()
  local body_data

  -- read in the body if we want to examine POST args
  if conf.key_in_body then
    ngx_req_read_body()
    body_data = public_tools.get_body_args()
  end

  -- search in headers & querystring
  for i = 1, #conf.key_names do
    local name = conf.key_names[i]
    local v = headers[name]
    if not v then
      -- search in querystring
      v = uri_args[name]
    end

    -- search the body, if we asked to
    if not v and conf.key_in_body then
      v = body_data[name]
    end

    if type(v) == "string" then
      key = v
      if conf.hide_credentials then
        uri_args[name] = nil
        set_uri_args(uri_args)
        clear_header(name)

        if conf.key_in_body then
          body_data[name] = nil
          ngx_req_set_body_data(ngx_encode_args(body_data))
        end
      end
      break
    elseif type(v) == "table" then
      -- duplicate API key, HTTP 401
      return false, {status = 401, message = "Duplicate API key found"}
    end
  end

  -- this request is missing an API key, HTTP 401
  if not key then
    ngx.header["WWW-Authenticate"] = _realm
    return false, { status = 401, message = "No API key found in request" }
  end

  -- retrieve our consumer linked to this API key
  local credential, err = cache.get_or_set(auth_cache.keyauth_referer_credential_key(key),
                                      nil, load_credential, key)
  if err then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  -- no credential in DB, for this key, it is invalid, HTTP 403
  if not credential then
    return false, {status = 403, message = "Invalid authentication credentials"}
  end

  local refererOk = testListReferer(credential.authorized_referer, headers["Referer"])

  if not refererOk then
    return false, {status = 403, message = "Invalid referer"}
  end

  -----------------------------------------
  -- Success, this request is authenticated
  -----------------------------------------

  -- retrieve the consumer linked to this API key, to set appropriate headers
  local consumer, err = cache.get_or_set(cache.consumer_key(credential.consumer_id),
                                    nil, load_consumer, credential.consumer_id)
  if err then
    return responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
  end

  set_consumer(consumer, credential)

  return true
end


function KeyAuthHandlerReferer:access(conf)
  KeyAuthHandlerReferer.super.access(self)

  if ngx.ctx.authenticated_credential and conf.anonymous ~= "" then
    -- we're already authenticated, and we're configured for using anonymous, 
    -- hence we're in a logical OR between auth methods and we're already done.
    return
  end

  local ok, err = do_authentication(conf)
  if not ok then
    if conf.anonymous ~= "" and conf.anonymous ~= nil then
      -- get anonymous user
      local consumer, err = cache.get_or_set(cache.consumer_key(conf.anonymous),
                            nil, load_consumer, conf.anonymous, true)
      if err then
        responses.send_HTTP_INTERNAL_SERVER_ERROR(err)
      end
      set_consumer(consumer, nil)
    else
      return responses.send(err.status, err.message)
    end
  end
end


return KeyAuthHandlerReferer