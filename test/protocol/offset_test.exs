defmodule Cafex.Protocol.Offset.Test do
  use ExUnit.Case, async: true

  alias Cafex.Protocol.Offset
  alias Cafex.Protocol.Offset.Request
  alias Cafex.Protocol.Offset.Response

  test "Offset protocol implementation" do
    req = %Request{}
    assert Offset.has_response?(req) == true
    assert Offset.decoder(req) == Offset
    assert Offset.api_key(req) == Cafex.Protocol.api_key(:offset)
    assert Offset.api_version(req) == 0
  end

  test "decode correctly parses a valid response with an offset" do
    response = << 1 :: 32, 3 :: 16, "bar" :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 1 :: 32, 10 :: 64 >>
    expected_response = %Response{offsets: [{"bar", [%{error: :no_error, offsets: [10], partition: 0}]}]}

    assert expected_response == Offset.decode(response)
  end

  test "decode correctly parses a valid response with multiple offsets" do
    response = << 1 :: 32, 3 :: 16, "bar" :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 2 :: 32, 10 :: 64, 20 :: 64 >>
    expected_response = %Response{offsets: [{"bar", [%{error: :no_error, offsets: [10, 20], partition: 0}]}]}

    assert expected_response == Offset.decode(response)
  end

  test "decode correctly parses a valid response with multiple partitions" do
    response = << 1 :: 32, 3 :: 16, "bar" :: binary, 2 :: 32, 0 :: 32, 0 :: 16, 1 :: 32, 10 :: 64, 1 :: 32, 0 :: 16, 1 :: 32, 20 :: 64 >>
    expected_response = %Response{offsets: [{"bar", [
            %{error: :no_error, offsets: [10], partition: 0},
            %{error: :no_error, offsets: [20], partition: 1}
          ]}]}

    assert expected_response == Offset.decode(response)
  end

  test "decode correctly parses a valid response with multiple topics" do
    response = << 2 :: 32, 3 :: 16, "bar" :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 1 :: 32, 10 :: 64, 3 :: 16, "baz" :: binary, 1 :: 32, 0 :: 32, 0 :: 16, 1 :: 32, 20 :: 64 >>
    expected_response = %Response{offsets: [
        {"bar", [%{error: :no_error, offsets: [10], partition: 0}]},
        {"baz", [%{error: :no_error, offsets: [20], partition: 0}]}
      ]}

    assert expected_response == Offset.decode(response)
  end
end
