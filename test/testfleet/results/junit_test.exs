defmodule TestFleet.Results.JUnitTest do
  use ExUnit.Case, async: true

  alias TestFleet.Results.JUnit

  test "parses every status with suite, class, duration, and failure" do
    xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <testsuites name="e2e">
      <testsuite name="checkout" tests="4">
        <testcase classname="Cart" name="adds an item" time="1.25"/>
        <testcase classname="Cart" name="pays" time="0.5">
          <failure message="expected 200, got 500" type="AssertionError">at pay (cart.spec.ts:12)
      at run</failure>
          <system-out>ignored</system-out>
        </testcase>
        <testcase classname="Cart" name="crashes" time="0">
          <error message="TypeError: x is undefined"/>
        </testcase>
        <testcase classname="Cart" name="later">
          <skipped/>
        </testcase>
      </testsuite>
    </testsuites>
    """

    assert {:ok, [passed, failed, error, skipped]} = JUnit.parse(xml)

    assert passed == %{
             suite: "checkout",
             classname: "Cart",
             name: "adds an item",
             status: :passed,
             duration_ms: 1250,
             failure_message: nil,
             failure_details: nil
           }

    assert %{
             status: :failed,
             duration_ms: 500,
             failure_message: "expected 200, got 500",
             failure_details: "at pay (cart.spec.ts:12)\n  at run"
           } = failed

    assert %{status: :error, failure_message: "TypeError: x is undefined", failure_details: nil} =
             error

    assert %{status: :skipped, duration_ms: nil} = skipped
  end

  test "a single testsuite at the root" do
    assert {:ok, [%{suite: "smoke", name: "loads", classname: ""}]} =
             JUnit.parse(~s(<testsuite name="smoke"><testcase name="loads"/></testsuite>))
  end

  test "nested suites use the innermost name" do
    xml = """
    <testsuites>
      <testsuite name="outer">
        <testsuite name="inner"><testcase name="a"/></testsuite>
        <testcase name="b"/>
      </testsuite>
    </testsuites>
    """

    assert {:ok, [%{suite: "inner", name: "a"}, %{suite: "outer", name: "b"}]} = JUnit.parse(xml)
  end

  test "an empty report has no cases" do
    assert {:ok, []} = JUnit.parse("<testsuites/>")
  end

  test "durations with thousands separators, or unreadable ones" do
    assert {:ok, [%{duration_ms: 1_234_500}, %{duration_ms: nil}]} =
             JUnit.parse(
               ~s(<testsuite><testcase name="a" time="1,234.5"/><testcase name="b" time="soon"/></testsuite>)
             )
  end

  test "keeps UTF-8 and entities" do
    assert {:ok, [%{name: "zahlt 5 € & mehr"}]} =
             JUnit.parse(~s(<testsuite><testcase name="zahlt 5 € &amp; mehr"/></testsuite>))
  end

  test "cuts failure details at 64 KiB" do
    details = String.duplicate("x", 100_000)

    xml =
      ~s(<testsuite><testcase name="a"><failure message="m">#{details}</failure></testcase></testsuite>)

    assert {:ok, [%{failure_details: cut}]} = JUnit.parse(xml)
    assert byte_size(cut) <= 65_536 + 8_192
    assert byte_size(cut) >= 65_536
  end

  test "rejects a DOCTYPE, which could expand entities" do
    xml = """
    <?xml version="1.0"?>
    <!DOCTYPE lolz [<!ENTITY lol "lol"><!ENTITY lol2 "&lol;&lol;&lol;">]>
    <testsuite><testcase name="&lol2;"/></testsuite>
    """

    assert {:error, "a DOCTYPE is not allowed"} = JUnit.parse(xml)
  end

  test "invalid XML is an error" do
    assert {:error, "invalid XML: " <> _} = JUnit.parse("<testsuite><testcase></testsuite>")
  end

  test "a document that is not JUnit is an error" do
    assert {:error, _} = JUnit.parse("<html><body>report</body></html>")
  end
end
