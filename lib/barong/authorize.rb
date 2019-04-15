# frozen_string_literal: true

module Barong
  # AuthZ functionality
  class Authorize
    # Custom Error class to support error status and message
    class AuthError < StandardError
      attr_reader :code

      # init an error with status and text to return in api response
      def initialize(code)
        super
        @code = code
      end
    end

    # init base request info, fetch black and white lists
    def initialize(request, path)
      @request = request
      session[:init] = true
      @path = path
      @rules = lists['rules']
    end

    # main: switch between cookie and api key logic, return bearer token
    def auth
      auth_type = 'cookie'
      auth_type = 'api_key' if api_key_headers?
      auth_owner = method("#{auth_type}_owner").call
      'Bearer ' + codec.encode(auth_owner.as_payload) # encoded user info
    end

    # cookies validations
    def cookie_owner
      error!({ errors: ['authz.invalid_session'] }, 401) unless session[:uid]

      user = User.find_by!(uid: session[:uid])
      error!({ errors: ['authz.user_not_active'] }, 401) unless user.active?

      error!({ errors: ['authz.invalid_permission'] }, 401) unless enough_permissions?(user)

      user # returns user(whose session is inside cookie)
    end

    # api key validations
    def api_key_owner
      api_key = APIKeysVerifier.new(api_key_params)

      error!({ errors: ['authz.invalid_signature'] }, 401) unless api_key.verify_hmac_payload?

      current_api_key = APIKey.find_by_kid(api_key_params[:kid])
      error!({ errors: ['authz.apikey_not_active'] }, 401) unless current_api_key.active?

      user = User.find_by_id(current_api_key.user_id)
      validate_user!(user)

      error!({ errors: ['authz.invalid_permission'] }, 401) unless enough_permissions?(user)

      user # returns user(api key creator)
    rescue ActiveRecord::RecordNotFound
      error!({ errors: ['authz.unexistent_apikey'] }, 401)
    end

    def enough_permissions?(user)
      target_permission = Permission.find_by_role_and_req_type_and_path(user.role, @request.env['REQUEST_METHOD'], @path)

      return false if target_permission.nil?

      true
    end

    # black/white list validation. takes ['block', 'pass'] as a parameter
    def restricted?(type)
      return false if @rules[type].nil? # if no authz rules provided

      @rules[type].each do |t|
        return true if @path.starts_with?(t) # if request path is inside the rules list
      end
      false # default
    end

    private

    # encode helper method
    def codec
      @_codec ||= Barong::JWT.new(key: Barong::App.config.keystore.private_key)
    end

    # fetch authz rules from yml
    def lists
      YAML.safe_load(
        ERB.new(
          File.read(
            ENV.fetch('AUTHZ_RULES_FILE', Rails.root.join('config', 'authz_rules.yml'))
          )
        ).result
      )
    end

    # checks if api key headers are present in request
    def api_key_headers?
      return false if headers['X-Auth-Apikey'].nil? &&
                      headers['X-Auth-Nonce'].nil? &&
                      headers['X-Auth-Signature'].nil?
      @api_key_headers = [headers['X-Auth-Apikey'], headers['X-Auth-Nonce'], headers['X-Auth-Signature']]
      validate_headers?
    end

    def validate_user!(user)
      error!({ errors: ['authz.invalid_session'] }, 401) unless user.active?

      error!({ errors: ['authz.disabled_2fa'] }, 401) unless user.otp
    end

    # api key headers nil, blank validation
    def validate_headers?
      @api_key_headers.each do |k|
        error!({ errors: ['authz.invalid_api_key_headers'] }, 422) if k.blank?
      end
    end

    # converts header into hash of parameters
    def api_key_params
      {
        'kid': headers['X-Auth-Apikey'],
        'nonce': headers['X-Auth-Nonce'],
        'signature':  headers['X-Auth-Signature']
      }
    end

    # custom error, calls AuthError class
    def error!(text, code)
      raise AuthError.new(code),  text.to_json
    end

    def headers
      @request.headers
    end

    def session
      @request.session
    end
  end
end
