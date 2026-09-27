defmodule TestFleet.Schedules.Timezones do
  @moduledoc """
  IANA time zone names for schedules.

  `list/0` offers the canonical zones from the IANA `zone1970.tab`, as bundled with
  the tz package, plus `Etc/UTC`. `valid?/1` accepts every name the time zone
  database knows, including links such as `UTC`.
  """

  zone_tab =
    :tz
    |> Application.app_dir("priv")
    |> Path.join("tzdata*/zone1970.tab")
    |> Path.wildcard()
    |> Enum.max()

  @external_resource zone_tab

  @zones zone_tab
         |> File.read!()
         |> String.split("\n", trim: true)
         |> Enum.reject(&String.starts_with?(&1, "#"))
         |> Enum.map(&(&1 |> String.split("\t") |> Enum.at(2)))
         |> Enum.concat(["Etc/UTC"])
         |> Enum.uniq()
         |> Enum.sort()

  @doc "Canonical zone names, sorted."
  def list, do: @zones

  def valid?(name) when is_binary(name) do
    match?({:ok, _}, DateTime.now(name))
  end

  def valid?(_), do: false

  @doc "The zone preselected in new schedules (`config :testfleet, :default_timezone`)."
  def default, do: Application.get_env(:testfleet, :default_timezone, "Etc/UTC")
end
