import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/micu_poker start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :micu_poker, MicuPokerWeb.Endpoint, server: true
end

if config_env() == :prod do
  database_url = MicuPoker.SecretFile.fetch!("DATABASE_URL")

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  pool_size =
    case Integer.parse(System.get_env("POOL_SIZE") || "10") do
      {value, ""} when value > 0 -> value
      _invalid -> raise "environment variable POOL_SIZE must be a positive integer"
    end

  config :micu_poker, MicuPoker.Repo,
    # ssl: true,
    url: database_url,
    pool_size: pool_size,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base = MicuPoker.SecretFile.fetch!("SECRET_KEY_BASE")

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must contain at least 64 bytes"
  end

  admin_credentials =
    case {System.get_env("ADMIN_USER"), MicuPoker.SecretFile.fetch("ADMIN_PASSWORD")} do
      {nil, :missing} ->
        nil

      {"", :missing} ->
        nil

      {username, {:ok, password}}
      when is_binary(username) and username != "" and byte_size(username) <= 128 and
             byte_size(password) >= 16 ->
        {username, password}

      {_username, _password} ->
        raise "ADMIN_USER and ADMIN_PASSWORD must both be valid, or both be absent"
    end

  config :micu_poker, admin_credentials: admin_credentials

  host = System.get_env("PHX_HOST") || "example.com"

  # Boot-time settings fail loudly rather than falling back: a release that
  # silently listened on the wrong port or the wrong interface would look
  # healthy to systemd while being unreachable through nginx. The runtime knobs
  # in MicuPoker.Config are the ones that degrade gracefully instead.
  parse_port = fn name, default ->
    case Integer.parse(System.get_env(name) || default) do
      {value, ""} when value > 0 and value < 65_536 ->
        value

      _invalid ->
        raise "environment variable #{name} must be a TCP port, got: #{System.get_env(name)}"
    end
  end

  port = parse_port.("PORT", "4000")

  bind_ip =
    (System.get_env("BIND_IP") || "127.0.0.1")
    |> to_charlist()
    |> :inet.parse_address()
    |> case do
      {:ok, address} ->
        address

      {:error, _reason} ->
        raise "environment variable BIND_IP must be an IP address, got: #{System.get_env("BIND_IP")}"
    end

  config :micu_poker, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # WebSocket origin allow-list. Defaults to the public host only; extra origins
  # (staging, alternate domains) can be added with a comma separated CHECK_ORIGIN.
  check_origin =
    case System.get_env("CHECK_ORIGIN") do
      nil ->
        ["https://#{host}", "//#{host}"]

      value ->
        value
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))
    end

  # Only forwarded headers arriving from these peers are trusted when resolving
  # the real client IP. nginx runs on loopback; Cloudflare sits in front of it.
  trusted_proxies =
    (System.get_env("TRUSTED_PROXIES") || "127.0.0.1/32,::1/128")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  config :micu_poker,
    trusted_proxies: trusted_proxies,
    trust_cloudflare: System.get_env("TRUST_CLOUDFLARE", "true") in ~w(true 1 yes)

  config :micu_poker, MicuPokerWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bound to loopback: nginx is the only public entry point.
      ip: bind_ip,
      port: port
    ],
    check_origin: check_origin,
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :micu_poker, MicuPokerWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :micu_poker, MicuPokerWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Also, you may need to configure the Swoosh API client of your choice if you
  # are not using SMTP. Here is an example of the configuration:
  #
  #     config :micu_poker, MicuPoker.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # For this example you need include a HTTP client required by Swoosh API client.
  # Swoosh supports Hackney and Finch out of the box:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Hackney
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
