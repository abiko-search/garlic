import Config

config :logger, level: :debug

config :logger, :console,
  format: "$date $time $metadata[$level] $message\n",
  metadata: [:circuit_id]
