defmodule Boostomatic.Service.Behaviour do
  @moduledoc """
  Behaviour for implementing different social media service integrations.
  """

  # Setup client for new service
  @callback prepare_client(map()) :: {:ok, term()} | {:error, term()}

  # Check if activity is compatible and should be boosted
  @callback validate_activity?(map(), map()) :: boolean()

  # Boost logic
  @callback boost(map(), map()) :: {:ok, String.t()} | {:error, term()}
end
