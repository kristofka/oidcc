-module(oidcc_token_test).

-include_lib("eunit/include/eunit.hrl").
-include_lib("jose/include/jose_jwk.hrl").
-include_lib("jose/include/jose_jws.hrl").
-include_lib("jose/include/jose_jwt.hrl").
-include_lib("oidcc/include/oidcc_provider_configuration.hrl").
-include_lib("oidcc/include/oidcc_token.hrl").

retrieve_none_test() ->
    PrivDir = code:priv_dir(oidcc),

    %% Enable none algorithm for test
    jose:unsecured_signing(true),

    {ok, _} = application:ensure_all_started(oidcc),

    TelemetryRef =
        telemetry_test:attach_event_handlers(
            self(),
            [
                [oidcc, request_token, start],
                [oidcc, request_token, stop]
            ]
        ),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),
    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [<<"client_secret_basic">>, "unsupported"]
        },

    Jwks = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),
    JwkSet = #jose_jwk{keys = {jose_jwk_set, [Jwks]}},

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10
        },

    Jwk = jose_jwk:generate_key(16),
    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"none">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(Jwk, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>
        }),

    ClientContext = oidcc_client_context:from_manual(Configuration, JwkSet, ClientId, ClientSecret),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            ?assertMatch({"authorization", _}, proplists:lookup("authorization", Header)),
            ?assertMatch(
                #{
                    <<"grant_type">> := <<"authorization_code">>,
                    <<"code">> := AuthCode,
                    <<"redirect_uri">> := LocalEndpoint
                },
                maps:from_list(uri_string:dissect_query(Body))
            ),
            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {error,
            {none_alg_used, #oidcc_token{
                id = #oidcc_token_id{token = Token, claims = Claims},
                access = #oidcc_token_access{token = AccessToken},
                refresh = none,
                scope = [<<"profile">>, <<"openid">>]
            }}},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    receive
        {[oidcc, request_token, start], TelemetryRef, #{}, #{
            issuer := <<"https://my.provider">>,
            client_id := ClientId
        }} ->
            ok
    after 2_000 ->
        ct:fail(timeout_receive_attach_event_handlers)
    end,

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

retrieve_rs256_with_rotation_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    TelemetryRef =
        telemetry_test:attach_event_handlers(
            self(),
            [
                [oidcc, request_token, start],
                [oidcc, request_token, stop]
            ]
        ),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [
                <<"client_secret_post">>, <<"client_secret_basic">>
            ]
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    JwkBeforeRefresh0 = jose_jwk:generate_key(16),
    JwkBeforeRefresh = JwkBeforeRefresh0#jose_jwk{fields = #{<<"kid">> => <<"kid1">>}},

    JwkAfterRefresh0 = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),
    JwkAfterRefresh = JwkAfterRefresh0#jose_jwk{fields = #{<<"kid">> => <<"kid2">>}},

    RefreshJwksFun = fun(_OldJwk, <<"kid2">>) -> {ok, JwkAfterRefresh} end,

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"RS256">>, <<"kid">> => <<"kid2">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(JwkAfterRefresh, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(
        Configuration, JwkBeforeRefresh, ClientId, ClientSecret
    ),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            ?assertMatch(none, proplists:lookup("authorization", Header)),
            ?assertMatch(
                #{
                    <<"grant_type">> := <<"authorization_code">>,
                    <<"code">> := AuthCode,
                    <<"redirect_uri">> := LocalEndpoint,
                    <<"client_id">> := ClientId,
                    <<"client_secret">> := ClientSecret
                },
                maps:from_list(uri_string:dissect_query(Body))
            ),
            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint, refresh_jwks => RefreshJwksFun}
        )
    ),

    receive
        {[oidcc, request_token, start], TelemetryRef, #{}, #{
            issuer := <<"https://my.provider">>,
            client_id := ClientId
        }} ->
            ok
    after 2_000 ->
        ct:fail(timeout_receive_attach_event_handlers)
    end,

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

retrieve_hs256_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok,
        #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
            Configuration} =
        oidcc_provider_configuration:decode_configuration(jose:decode(ConfigurationBinary)),

    ClientId = <<"client_id">>,
    ClientSecret = <<"at_least_32_character_client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_oct(<<"at_least_32_character_client_secret">>),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"HS256">>},
    {_Jws, Token} = jose_jws:compact(jose_jwt:sign(Jwk, Jws, Jwt)),

    OtherJwk = jose_jwk:from_file(PrivDir ++ "/test/fixtures/openid-certification-jwks.json"),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(
        Configuration, OtherJwk, ClientId, ClientSecret
    ),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, _Header, "application/x-www-form-urlencoded", _Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

retrieve_hs256_with_max_clock_skew_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok,
        #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
            Configuration} =
        oidcc_provider_configuration:decode_configuration(jose:decode(ConfigurationBinary)),

    ClientId = <<"client_id">>,
    ClientSecret = <<"at_least_32_character_client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"nbf">> => erlang:system_time(second) + 5,
            <<"iat">> => erlang:system_time(second) + 5,
            <<"exp">> => erlang:system_time(second) + 15,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_oct(<<"at_least_32_character_client_secret">>),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"HS256">>},
    {_Jws, Token} = jose_jws:compact(jose_jwt:sign(Jwk, Jws, Jwt)),

    OtherJwk = jose_jwk:from_file(PrivDir ++ "/test/fixtures/openid-certification-jwks.json"),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(
        Configuration, OtherJwk, ClientId, ClientSecret
    ),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, _Header, "application/x-www-form-urlencoded", _Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {error, token_not_yet_valid},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    application:set_env(oidcc, max_clock_skew, 10),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    application:unset_env(oidcc, max_clock_skew),

    ok.

auth_method_client_secret_jwt_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [
                <<"client_secret_jwt">>, <<"client_secret_basic">>
            ],
            token_endpoint_auth_signing_alg_values_supported = [<<"HS256">>]
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"RS256">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(Jwk, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(Configuration, Jwk, ClientId, ClientSecret),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            ?assertMatch(none, proplists:lookup("authorization", Header)),
            BodyMap = maps:from_list(uri_string:dissect_query(Body)),

            CharlistAuthCode = binary:bin_to_list(AuthCode),
            CharlistClientId = binary:bin_to_list(ClientId),

            ?assertMatch(
                #{
                    "grant_type" := "authorization_code",
                    "code" := CharlistAuthCode,
                    "client_id" := CharlistClientId,
                    "client_assertion_type" :=
                        "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                    "client_assertion" := _
                },
                BodyMap
            ),

            ClientAssertion = maps:get("client_assertion", BodyMap),

            {true, ClientAssertionJwt, ClientAssertionJws} = jose_jwt:verify(
                jose_jwk:from_oct(ClientSecret), binary:list_to_bin(ClientAssertion)
            ),

            ?assertMatch(#jose_jws{alg = {jose_jws_alg_hmac, 'HS256'}}, ClientAssertionJws),

            ?assertMatch(
                #jose_jwt{
                    fields = #{
                        <<"aud">> := TokenEndpoint,
                        <<"exp">> := _,
                        <<"iat">> := _,
                        <<"iss">> := ClientId,
                        <<"jti">> := _,
                        <<"nbf">> := _,
                        <<"sub">> := ClientId
                    }
                },
                ClientAssertionJwt
            ),

            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

auth_method_client_secret_jwt_with_max_clock_skew_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [
                <<"client_secret_jwt">>, <<"client_secret_basic">>
            ],
            token_endpoint_auth_signing_alg_values_supported = [<<"HS256">>]
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"RS256">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(Jwk, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(Configuration, Jwk, ClientId, ClientSecret),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, _, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            BodyMap = maps:from_list(uri_string:dissect_query(Body)),

            ClientAssertion = maps:get("client_assertion", BodyMap),

            {true, ClientAssertionJwt, _} = jose_jwt:verify(
                jose_jwk:from_oct(ClientSecret), binary:list_to_bin(ClientAssertion)
            ),

            #jose_jwt{
                fields = #{
                    <<"nbf">> := ClientTokenNbf
                }
            } = ClientAssertionJwt,

            ?assert(ClientTokenNbf < os:system_time(seconds) - 5),

            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    application:set_env(oidcc, max_clock_skew, 10),

    oidcc_token:retrieve(
        AuthCode,
        ClientContext,
        #{redirect_uri => LocalEndpoint}
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    application:unset_env(oidcc, max_clock_skew),

    ok.

auth_method_private_key_jwt_no_supported_alg_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [
                <<"private_key_jwt">>, <<"client_secret_post">>
            ],
            token_endpoint_auth_signing_alg_values_supported = [<<"unsupported">>]
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"RS256">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(Jwk, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(Configuration, Jwk, ClientId, ClientSecret),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,

            ?assertMatch(none, proplists:lookup("authorization", Header)),

            ?assertMatch(
                #{
                    <<"grant_type">> := <<"authorization_code">>,
                    <<"code">> := AuthCode,
                    <<"client_id">> := ClientId,
                    <<"client_secret">> := ClientSecret
                },
                maps:from_list(uri_string:dissect_query(Body))
            ),

            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

auth_method_private_key_jwt_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [<<"private_key_jwt">>],
            token_endpoint_auth_signing_alg_values_supported = [<<"RS256">>]
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"RS256">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(Jwk, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientJwk0 = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),
    ClientJwk = ClientJwk0#jose_jwk{fields = #{<<"use">> => <<"sig">>}},

    ClientContext = oidcc_client_context:from_manual(Configuration, Jwk, ClientId, ClientSecret, #{
        client_jwks => ClientJwk
    }),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            ?assertMatch(none, proplists:lookup("authorization", Header)),
            BodyMap = maps:from_list(uri_string:dissect_query(Body)),

            CharlistAuthCode = binary:bin_to_list(AuthCode),
            CharlistClientId = binary:bin_to_list(ClientId),

            ?assertMatch(
                #{
                    "grant_type" := "authorization_code",
                    "code" := CharlistAuthCode,
                    "client_id" := CharlistClientId,
                    "client_assertion_type" :=
                        "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
                    "client_assertion" := _
                },
                BodyMap
            ),

            ClientAssertion = maps:get("client_assertion", BodyMap),

            {true, ClientAssertionJwt, ClientAssertionJws} = jose_jwt:verify(
                ClientJwk, binary:list_to_bin(ClientAssertion)
            ),

            ?assertMatch(
                #jose_jws{alg = {_, 'RS256'}}, ClientAssertionJws
            ),

            ?assertMatch(
                #jose_jwt{
                    fields = #{
                        <<"aud">> := TokenEndpoint,
                        <<"exp">> := _,
                        <<"iat">> := _,
                        <<"iss">> := ClientId,
                        <<"jti">> := _,
                        <<"nbf">> := _,
                        <<"sub">> := ClientId
                    }
                },
                ClientAssertionJwt
            ),

            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

auth_method_client_secret_jwt_no_alg_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [
                <<"client_secret_jwt">>
            ],
            token_endpoint_auth_signing_alg_values_supported = undefined
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,

    Jwk = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),

    ClientContext = oidcc_client_context:from_manual(Configuration, Jwk, ClientId, ClientSecret),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, _Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            BodyMap = maps:from_list(uri_string:dissect_query(Body)),

            ClientAssertion = maps:get("client_assertion", BodyMap),

            {true, _ClientAssertionJwt, ClientAssertionJws} = jose_jwt:verify(
                jose_jwk:from_oct(ClientSecret), binary:list_to_bin(ClientAssertion)
            ),

            ?assertMatch({jose_jws_alg_hmac, 'HS256'}, ClientAssertionJws#jose_jws.alg),

            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], <<"{}">>}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{}},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.

preferred_auth_methods_test() ->
    PrivDir = code:priv_dir(oidcc),

    {ok, _} = application:ensure_all_started(oidcc),

    {ok, ConfigurationBinary} = file:read_file(PrivDir ++ "/test/fixtures/example-metadata.json"),
    {ok, Configuration0} = oidcc_provider_configuration:decode_configuration(
        jose:decode(ConfigurationBinary)
    ),

    #oidcc_provider_configuration{token_endpoint = TokenEndpoint, issuer = Issuer} =
        Configuration = Configuration0#oidcc_provider_configuration{
            token_endpoint_auth_methods_supported = [
                <<"client_secret_jwt">>, <<"client_secret_basic">>
            ],
            token_endpoint_auth_signing_alg_values_supported = [<<"HS256">>]
        },

    ClientId = <<"client_id">>,
    ClientSecret = <<"client_secret">>,
    LocalEndpoint = <<"https://my.server/auth">>,
    AuthCode = <<"1234567890">>,
    AccessToken = <<"access_token">>,
    RefreshToken = <<"refresh_token">>,
    Claims =
        #{
            <<"iss">> => Issuer,
            <<"sub">> => <<"sub">>,
            <<"aud">> => ClientId,
            <<"iat">> => erlang:system_time(second),
            <<"exp">> => erlang:system_time(second) + 10,
            <<"at_hash">> => <<"hrOQHuo3oE6FR82RIiX1SA">>
        },

    Jwk = jose_jwk:from_pem_file(PrivDir ++ "/test/fixtures/jwk.pem"),

    Jwt = jose_jwt:from(Claims),
    Jws = #{<<"alg">> => <<"RS256">>},
    {_Jws, Token} =
        jose_jws:compact(
            jose_jwt:sign(Jwk, Jws, Jwt)
        ),

    TokenData =
        jsx:encode(#{
            <<"access_token">> => AccessToken,
            <<"token_type">> => <<"Bearer">>,
            <<"id_token">> => Token,
            <<"scope">> => <<"profile openid">>,
            <<"refresh_token">> => RefreshToken
        }),

    ClientContext = oidcc_client_context:from_manual(Configuration, Jwk, ClientId, ClientSecret),

    ok = meck:new(httpc, [no_link]),
    HttpFun =
        fun(
            post,
            {ReqTokenEndpoint, Header, "application/x-www-form-urlencoded", Body},
            _HttpOpts,
            _Opts
        ) ->
            TokenEndpoint = ReqTokenEndpoint,
            ?assertMatch({"authorization", _}, proplists:lookup("authorization", Header)),
            BodyMap = maps:from_list(uri_string:dissect_query(Body)),

            ?assertMatch(
                #{
                    <<"grant_type">> := <<"authorization_code">>,
                    <<"code">> := AuthCode,
                    <<"redirect_uri">> := LocalEndpoint
                },
                BodyMap
            ),

            ?assertMatch(none, maps:get("client_assertion", BodyMap, none)),

            {ok, {{"HTTP/1.1", 200, "OK"}, [{"content-type", "application/json"}], TokenData}}
        end,
    ok = meck:expect(httpc, request, HttpFun),

    ?assertMatch(
        {ok, #oidcc_token{
            id = #oidcc_token_id{token = Token, claims = Claims},
            access = #oidcc_token_access{token = AccessToken},
            refresh = #oidcc_token_refresh{token = RefreshToken},
            scope = [<<"profile">>, <<"openid">>]
        }},
        oidcc_token:retrieve(
            AuthCode,
            ClientContext,
            #{redirect_uri => LocalEndpoint, preferred_auth_methods => [client_secret_basic]}
        )
    ),

    true = meck:validate(httpc),

    meck:unload(httpc),

    ok.
