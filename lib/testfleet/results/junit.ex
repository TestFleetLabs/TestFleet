defmodule TestFleet.Results.JUnit do
  @moduledoc """
  Parses JUnit XML into test cases.

  A pure function without database or configuration, so `RunExecution` can call it
  where the files are extracted.

  Accepts `<testsuites>` or a single `<testsuite>` at the root, and nested suites;
  a case's `suite` is its innermost enclosing suite. `<failure>` makes a case
  `failed`, `<error>` `error`, `<skipped>` `skipped`; otherwise it `passed`.

  Safety: a JUnit file comes from the suite, so it is untrusted. Documents with a
  `<!DOCTYPE` are rejected, which rules out entity expansion, and external entities
  are never loaded. Callers limit the file size.
  """

  @max_details_bytes 65_536

  @type test_case :: %{
          suite: String.t(),
          classname: String.t(),
          name: String.t(),
          status: :passed | :failed | :error | :skipped,
          duration_ms: non_neg_integer() | nil,
          failure_message: String.t() | nil,
          failure_details: String.t() | nil
        }

  @spec parse(binary()) :: {:ok, [test_case()]} | {:error, String.t()}
  def parse(xml) when is_binary(xml) do
    if String.contains?(xml, "<!DOCTYPE") do
      {:error, "a DOCTYPE is not allowed"}
    else
      sax(xml)
    end
  end

  defp sax(xml) do
    state = %{suites: [], current: nil, text: nil, cases: [], seen_root: false}

    case :xmerl_sax_parser.stream(xml,
           event_fun: &event/3,
           event_state: state,
           external_entities: :none
         ) do
      {:ok, %{seen_root: true} = state, _rest} ->
        {:ok, Enum.reverse(state.cases)}

      {:ok, _state, _rest} ->
        {:error, "no <testsuites> or <testsuite> element"}

      {:fatal_error, _location, reason, _end_tags, _state} ->
        {:error, "invalid XML: #{format_reason(reason)}"}

      {_tag, _location, reason, _end_tags, _state} ->
        {:error, format_reason(reason)}
    end
  end

  defp format_reason(reason) when is_list(reason), do: List.to_string(reason)
  defp format_reason(reason), do: inspect(reason)

  ## Events

  defp event({:startElement, _uri, name, _qname, attributes}, _location, state) do
    start_element(List.to_string(name), attributes(attributes), state)
  end

  defp event({:endElement, _uri, name, _qname}, _location, state) do
    end_element(List.to_string(name), state)
  end

  defp event({:characters, chars}, _location, %{text: {iodata, size}} = state)
       when size < @max_details_bytes do
    chunk = List.to_string(chars)
    %{state | text: {[iodata | chunk], size + byte_size(chunk)}}
  end

  defp event(_event, _location, state), do: state

  defp start_element("testsuites", _attrs, state), do: %{state | seen_root: true}

  defp start_element("testsuite", attrs, state),
    do: push_suite(%{state | seen_root: true}, attrs)

  defp start_element("testcase", attrs, state) do
    case_ = %{
      suite: List.first(state.suites) || "",
      classname: attrs["classname"] || "",
      name: attrs["name"] || "",
      status: :passed,
      duration_ms: duration_ms(attrs["time"]),
      failure_message: nil,
      failure_details: nil
    }

    %{state | current: case_}
  end

  defp start_element(kind, attrs, %{current: %{status: status} = case_} = state)
       when kind in ["failure", "error"] and status in [:passed, :skipped] do
    status = if kind == "failure", do: :failed, else: :error

    %{
      state
      | current: %{case_ | status: status, failure_message: attrs["message"]},
        text: {[], 0}
    }
  end

  defp start_element("skipped", _attrs, %{current: %{status: :passed} = case_} = state),
    do: %{state | current: %{case_ | status: :skipped}}

  defp start_element(_name, _attrs, state), do: state

  defp push_suite(state, attrs), do: %{state | suites: [attrs["name"] || "" | state.suites]}

  defp end_element("testsuite", %{suites: [_ | rest]} = state), do: %{state | suites: rest}

  defp end_element("testcase", %{current: case_} = state) when case_ != nil,
    do: %{state | current: nil, cases: [case_ | state.cases]}

  defp end_element(kind, %{current: case_, text: {iodata, _size}} = state)
       when kind in ["failure", "error"] do
    details = iodata |> IO.iodata_to_binary() |> cut() |> String.trim()
    %{state | current: %{case_ | failure_details: blank_to_nil(details)}, text: nil}
  end

  defp end_element(_name, state), do: state

  ## Helpers

  defp attributes(attributes) do
    Map.new(attributes, fn {_uri, _prefix, name, value} ->
      {List.to_string(name), List.to_string(value)}
    end)
  end

  # Seconds, possibly fractional; some reporters write thousands separators.
  defp duration_ms(nil), do: nil

  defp duration_ms(time) do
    case time |> String.replace(",", "") |> Float.parse() do
      {seconds, _rest} when seconds >= 0 -> round(seconds * 1000)
      _ -> nil
    end
  end

  defp cut(details) when byte_size(details) <= @max_details_bytes, do: details

  # A multibyte character cut in half is replaced, not left invalid.
  defp cut(details),
    do: details |> binary_part(0, @max_details_bytes) |> String.replace_invalid()

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
