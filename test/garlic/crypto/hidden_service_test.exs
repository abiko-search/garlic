defmodule Garlic.Crypto.HiddenServiceTest do
  use ExUnit.Case

  import Garlic.Crypto.HiddenService
  import Base

  test "build index" do
    assert build_index(String.duplicate("\x42", 32), 1, 1440, 42) ==
             decode16!("37E5CBBD56A22823714F18F1623ECE5983A0D64C78495A8CFAB854245E5F9A8A")
  end

  test "build directory index" do
    assert build_directory_index(
             String.duplicate("\x42", 32),
             String.duplicate("\x43", 32),
             1440,
             42
           ) ==
             decode16!("DB475361014A09965E7E5E4D4A25B8F8D4B8F16CB1D8A7E95EED50249CC1A2D5")
  end
end
