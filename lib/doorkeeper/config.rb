# frozen_string_literal: true

require "doorkeeper/config/option"

module Doorkeeper
  class MissingConfiguration < StandardError
    # Defines a MissingConfiguration error for a missing Doorkeeper
    # configuration
    def initialize
      super("Configuration for doorkeeper missing. Do you have doorkeeper initializer?")
    end
  end

  def self.configure(&block)
    @config = Config::Builder.new(&block).build
    setup_orm_adapter
    setup_orm_models
    setup_application_owner if @config.enable_application_owner?
    @config
  end

  def self.configuration
    @config || (raise MissingConfiguration)
  end

  def self.setup_orm_adapter
    @orm_adapter = "doorkeeper/orm/#{configuration.orm}".classify.constantize
  rescue NameError => e
    raise e, "ORM adapter not found (#{configuration.orm})", <<-ERROR_MSG.strip_heredoc
      [doorkeeper] ORM adapter not found (#{configuration.orm}), or there was an error
      trying to load it.

      You probably need to add the related gem for this adapter to work with
      doorkeeper.
    ERROR_MSG
  end

  def self.setup_orm_models
    @orm_adapter.initialize_models!
  end

  def self.setup_application_owner
    @orm_adapter.initialize_application_owner!
  end

  class Config
    class Builder
      def initialize(&block)
        @config = Config.new
        instance_eval(&block)
      end

      def build
        @config.validate
        @config
      end

      # Provide support for an owner to be assigned to each registered
      # application (disabled by default)
      # Optional parameter confirmation: true (default false) if you want
      # to enforce ownership of a registered application
      #
      # @param opts [Hash] the options to confirm if an application owner
      #   is present
      # @option opts[Boolean] :confirmation (false)
      #   Set confirm_application_owner variable
      def enable_application_owner(opts = {})
        @config.instance_variable_set(:@enable_application_owner, true)
        confirm_application_owner if opts[:confirmation].present? && opts[:confirmation]
      end

      def confirm_application_owner
        @config.instance_variable_set(:@confirm_application_owner, true)
      end

      # Define default access token scopes for your provider
      #
      # @param scopes [Array] Default set of access (OAuth::Scopes.new)
      # token scopes
      def default_scopes(*scopes)
        @config.instance_variable_set(:@default_scopes, OAuth::Scopes.from_array(scopes))
      end

      # Define default access token scopes for your provider
      #
      # @param scopes [Array] Optional set of access (OAuth::Scopes.new)
      # token scopes
      def optional_scopes(*scopes)
        @config.instance_variable_set(:@optional_scopes, OAuth::Scopes.from_array(scopes))
      end

      # Define scopes_by_grant_type to limit certain scope to certain grant_type
      # @param { Hash } with grant_types as keys.
      # Default set to {} i.e. no limitation on scopes usage
      def scopes_by_grant_type(hash = {})
        @config.instance_variable_set(:@scopes_by_grant_type, hash)
      end

      # Change the way client credentials are retrieved from the request object.
      # By default it retrieves first from the `HTTP_AUTHORIZATION` header, then
      # falls back to the `:client_id` and `:client_secret` params from the
      # `params` object.
      #
      # @param methods [Array] Define client credentials
      def client_credentials(*methods)
        @config.instance_variable_set(:@client_credentials_methods, methods)
      end

      # Change the way access token is authenticated from the request object.
      # By default it retrieves first from the `HTTP_AUTHORIZATION` header, then
      # falls back to the `:access_token` or `:bearer_token` params from the
      # `params` object.
      #
      # @param methods [Array] Define access token methods
      def access_token_methods(*methods)
        @config.instance_variable_set(:@access_token_methods, methods)
      end

      # Issue access tokens with refresh token (disabled if not set)
      def use_refresh_token(enabled = true, &block)
        @config.instance_variable_set(
          :@refresh_token_enabled,
          block || enabled
        )
      end

      # Reuse access token for the same resource owner within an application
      # (disabled by default)
      # Rationale: https://github.com/doorkeeper-gem/doorkeeper/issues/383
      def reuse_access_token
        @config.instance_variable_set(:@reuse_access_token, true)
      end

      # Sets the token_reuse_limit
      # It will be used only when reuse_access_token option in enabled
      # By default it will be 100
      # It will be used for token reusablity to some threshold percentage
      # Rationale: https://github.com/doorkeeper-gem/doorkeeper/issues/1189
      def token_reuse_limit(percentage)
        @config.instance_variable_set(:@token_reuse_limit, percentage)
      end

      # Use an API mode for applications generated with --api argument
      # It will skip applications controller, disable forgery protection
      def api_only
        @config.instance_variable_set(:@api_only, true)
      end

      # Forbids creating/updating applications with arbitrary scopes that are
      # not in configuration, i.e. `default_scopes` or `optional_scopes`.
      # (disabled by default)
      def enforce_configured_scopes
        @config.instance_variable_set(:@enforce_configured_scopes, true)
      end

      # Enforce request content type as the spec requires:
      # disabled by default for backward compatibility.
      def enforce_content_type
        @config.instance_variable_set(:@enforce_content_type, true)
      end

      # Allow optional hashing of input tokens before persisting them.
      # Will be used for hashing of input token and grants.
      #
      # @param using
      #   Provide a different secret storage implementation class for tokens
      # @param fallback
      #   Provide a fallback secret storage implementation class for tokens
      #   or use :plain to fallback to plain tokens
      def hash_token_secrets(using: nil, fallback: nil)
        default = "::Doorkeeper::SecretStoring::Sha256Hash"
        configure_secrets_for :token,
                              using: using || default,
                              fallback: fallback
      end

      # Allow optional hashing of application secrets before persisting them.
      # Will be used for hashing of input token and grants.
      #
      # @param using
      #   Provide a different secret storage implementation for applications
      # @param fallback
      #   Provide a fallback secret storage implementation for applications
      #   or use :plain to fallback to plain application secrets
      def hash_application_secrets(using: nil, fallback: nil)
        default = "::Doorkeeper::SecretStoring::Sha256Hash"
        configure_secrets_for :application,
                              using: using || default,
                              fallback: fallback
      end

      private

      # Configure the secret storing functionality
      def configure_secrets_for(type, using:, fallback:)
        raise ArgumentError, "Invalid type #{type}" if %i[application token].exclude?(type)

        @config.instance_variable_set(:"@#{type}_secret_strategy",
                                      using.constantize)

        if fallback.nil?
          return
        elsif fallback.to_sym == :plain
          fallback = "::Doorkeeper::SecretStoring::Plain"
        end

        @config.instance_variable_set(:"@#{type}_secret_fallback_strategy",
                                      fallback.constantize)
      end
    end

    extend Option

    option :resource_owner_authenticator,
           as: :authenticate_resource_owner,
           default: (lambda do |_routes|
             ::Rails.logger.warn(
               I18n.t("doorkeeper.errors.messages.resource_owner_authenticator_not_configured")
             )

             nil
           end)

    option :admin_authenticator,
           as: :authenticate_admin,
           default: (lambda do |_routes|
             ::Rails.logger.warn(
               I18n.t("doorkeeper.errors.messages.admin_authenticator_not_configured")
             )

             head :forbidden
           end)

    option :resource_owner_from_credentials,
           default: (lambda do |_routes|
             ::Rails.logger.warn(
               I18n.t("doorkeeper.errors.messages.credential_flow_not_configured")
             )

             nil
           end)

    # Hooks for authorization
    option :before_successful_authorization,      default: ->(_context) {}
    option :after_successful_authorization,       default: ->(_context) {}
    # Hooks for strategies responses
    option :before_successful_strategy_response,  default: ->(_request) {}
    option :after_successful_strategy_response,   default: ->(_request, _response) {}
    # Allows to customize Token Introspection response
    option :custom_introspection_response,        default: ->(_token, _context) { {} }

    option :skip_authorization,             default: ->(_routes) {}
    option :access_token_expires_in,        default: 7200
    option :custom_access_token_expires_in, default: ->(_context) { nil }
    option :authorization_code_expires_in,  default: 600
    option :orm,                            default: :active_record
    option :native_redirect_uri,            default: "urn:ietf:wg:oauth:2.0:oob", deprecated: true
    option :active_record_options,          default: {}
    option :grant_flows,                    default: %w[authorization_code client_credentials]
    option :handle_auth_errors,             default: :render

    # Allows to forbid specific Application redirect URI's by custom rules.
    # Doesn't forbid any URI by default.
    #
    # @param forbid_redirect_uri [Proc] Block or any object respond to #call
    #
    option :forbid_redirect_uri,            default: ->(_uri) { false }

    # WWW-Authenticate Realm (default "Doorkeeper").
    #
    # @param realm [String] ("Doorkeeper") Authentication realm
    #
    option :realm,                          default: "Doorkeeper"

    # Forces the usage of the HTTPS protocol in non-native redirect uris
    # (enabled by default in non-development environments). OAuth2
    # delegates security in communication to the HTTPS protocol so it is
    # wise to keep this enabled.
    #
    # @param [Boolean] boolean_or_block value for the parameter, true by default in
    # non-development environment
    #
    # @yield [uri] Conditional usage of SSL redirect uris.
    # @yieldparam [URI] Redirect URI
    # @yieldreturn [Boolean] Indicates necessity of usage of the HTTPS protocol
    #   in non-native redirect uris
    #
    option :force_ssl_in_redirect_uri,      default: !Rails.env.development?

    # Use a custom class for generating the access token.
    # https://doorkeeper.gitbook.io/guides/configuration/other-configurations#custom-access-token-generator
    #
    # @param access_token_generator [String]
    #   the name of the access token generator class
    #
    option :access_token_generator,
           default: "Doorkeeper::OAuth::Helpers::UniqueToken"

    # Default access token generator is a SecureRandom class from Ruby stdlib.
    # This option defines which method will be used to generate a unique token value.
    #
    # @param access_token_generator [String]
    #   the name of the access token generator class
    #
    option :default_generator_method, default: :urlsafe_base64

    # The controller Doorkeeper::ApplicationController inherits from.
    # Defaults to ActionController::Base.
    # https://doorkeeper.gitbook.io/guides/configuration/other-configurations#custom-base-controller
    #
    # @param base_controller [String] the name of the base controller
    option :base_controller,
           default: "ActionController::Base"

    # The controller Doorkeeper::ApplicationMetalController inherits from.
    # Defaults to ActionController::API.
    #
    # @param base_metal_controller [String] the name of the base controller
    option :base_metal_controller,
           default: "ActionController::API"

    # Allows to set blank redirect URIs for Applications in case
    # server configured to use URI-less grant flows.
    #
    option :allow_blank_redirect_uri,
           default: (lambda do |grant_flows, _application|
             grant_flows.exclude?("authorization_code") &&
               grant_flows.exclude?("implicit")
           end)

    # Configure protection of token introspection request.
    # By default this configuration allows to introspect a token by
    # another token of the same application, or to introspect the token
    # that belongs to authorized client, or access token has been introspected
    # is a public one (doesn't belong to any client)
    #
    # You can define any custom rule you need or just disable token
    # introspection at all.
    #
    # @param token [Doorkeeper::AccessToken]
    #   token to be introspected
    #
    # @param authorized_client [Doorkeeper::Application]
    #   authorized client (if request is authorized using Basic auth with
    #   Client Credentials for example)
    #
    # @param authorized_token [Doorkeeper::AccessToken]
    #   Bearer token used to authorize the request
    #
    option :allow_token_introspection,
           default: (lambda do |token, authorized_client, authorized_token|
             if authorized_token
               authorized_token.application == token&.application
             elsif token.application
               authorized_client == token.application
             else
               true
             end
           end)

    attr_reader :api_only,
                :enforce_content_type,
                :reuse_access_token,
                :token_secret_fallback_strategy,
                :application_secret_fallback_strategy

    # Return the valid subset of this configuration
    def validate
      validate_reuse_access_token_value
      validate_token_reuse_limit
      validate_secret_strategies
    end

    def api_only
      @api_only ||= false
    end

    def enforce_content_type
      @enforce_content_type ||= false
    end

    def refresh_token_enabled?
      if defined?(@refresh_token_enabled)
        @refresh_token_enabled
      else
        false
      end
    end

    def token_reuse_limit
      @token_reuse_limit ||= 100
    end

    def enforce_configured_scopes?
      option_set? :enforce_configured_scopes
    end

    def enable_application_owner?
      option_set? :enable_application_owner
    end

    def confirm_application_owner?
      option_set? :confirm_application_owner
    end

    def raise_on_errors?
      handle_auth_errors == :raise
    end

    def token_secret_strategy
      @token_secret_strategy ||= ::Doorkeeper::SecretStoring::Plain
    end

    def application_secret_strategy
      @application_secret_strategy ||= ::Doorkeeper::SecretStoring::Plain
    end

    def default_scopes
      @default_scopes ||= OAuth::Scopes.new
    end

    def optional_scopes
      @optional_scopes ||= OAuth::Scopes.new
    end

    def scopes
      @scopes ||= default_scopes + optional_scopes
    end

    def scopes_by_grant_type
      @scopes_by_grant_type ||= {}
    end

    def client_credentials_methods
      @client_credentials_methods ||= %i[from_basic from_params]
    end

    def access_token_methods
      @access_token_methods ||= %i[
        from_bearer_authorization
        from_access_token_param
        from_bearer_param
      ]
    end

    def authorization_response_types
      @authorization_response_types ||= calculate_authorization_response_types.freeze
    end

    def token_grant_types
      @token_grant_types ||= calculate_token_grant_types.freeze
    end

    def allow_blank_redirect_uri?(application = nil)
      if allow_blank_redirect_uri.respond_to?(:call)
        allow_blank_redirect_uri.call(grant_flows, application)
      else
        allow_blank_redirect_uri
      end
    end

    def option_defined?(name)
      instance_variable_defined?("@#{name}")
    end

    private

    # Helper to read boolearized configuration option
    def option_set?(instance_key)
      var = instance_variable_get("@#{instance_key}")
      !!(defined?(var) && var)
    end

    # Determines what values are acceptable for 'response_type' param in
    # authorization request endpoint, and return them as an array of strings.
    #
    def calculate_authorization_response_types
      types = []
      types << "code"  if grant_flows.include? "authorization_code"
      types << "token" if grant_flows.include? "implicit"
      types
    end

    # Determines what values are acceptable for 'grant_type' param token
    # request endpoint, and return them in array.
    #
    def calculate_token_grant_types
      types = grant_flows - ["implicit"]
      types << "refresh_token" if refresh_token_enabled?
      types
    end

    # Determine whether +reuse_access_token+ and a non-restorable
    # +token_secret_strategy+ have both been activated.
    #
    # In that case, disable reuse_access_token value and warn the user.
    def validate_reuse_access_token_value
      strategy = token_secret_strategy
      return if !reuse_access_token || strategy.allows_restoring_secrets?

      ::Rails.logger.warn(
        "You have configured both reuse_access_token " \
        "AND strategy strategy '#{strategy}' that cannot restore tokens. " \
        "This combination is unsupported. reuse_access_token will be disabled"
      )
      @reuse_access_token = false
    end

    # Validate that the provided strategies are valid for
    # tokens and applications
    def validate_secret_strategies
      token_secret_strategy.validate_for :token
      application_secret_strategy.validate_for :application
    end

    def validate_token_reuse_limit
      return if !reuse_access_token ||
                (token_reuse_limit > 0 && token_reuse_limit <= 100)

      ::Rails.logger.warn(
        "You have configured an invalid value for token_reuse_limit option. " \
        "It will be set to default 100"
      )
      @token_reuse_limit = 100
    end
  end
end
