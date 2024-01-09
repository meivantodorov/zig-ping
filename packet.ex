defmodule Zing.Packet do

  defstruct [:type, :id, seq: 0]

  @type_to_code %{request: <<8, 0>>}

  ## Also used as identifier
  @empty_checksum <<0, 0>>

  #############################################################################
  ## API

  ## packet = Packet.encode(type: :request, id: from)
  ## Code.require_file("packet.ex")
  ## Zing.Packet.encode(type: :request, id: self())
  def encode(list) when is_list(list), do: encode(struct(__MODULE__, list))
  def encode(%__MODULE__{type: :request, id: _id, seq: _seq}) do   
  <<8, 0, 0, 0, 0, 0, 240, 86, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0>>
  |> insert_checksum()
    # insert_checksum(
    #   <<@type_to_code[:request] :: binary, @empty_checksum :: binary,
    #     seq :: 16, :erlang.phash2(id) :: 16, random_payload() :: binary>>)
  end

  def decode(binary) do
    IO.inspect(binary)
  end

  #############################################################################
  ## helper functions: encode

  ## https://i.stack.imgur.com/Yp1XM.png
  def insert_checksum(payload = <<first::16, @empty_checksum>> <> rest) do    
    <<first::16, sum16compl(payload) :: 16, rest :: binary>>
  end

  def sum16compl(binary, sum16 \\ 0)
  def sum16compl(<<first::16>>, sum16) do
    IO.puts("#{first + sum16}")    
    Bitwise.~~~(first + sum16)
  end
  def sum16compl(<<first::16>> <> rest, sum16) do    
    sum16compl(rest, first + sum16)
  end

  defp random_payload, do: <<0::56 * 8>> #:crypto.strong_rand_bytes(56)

  #############################################################################
  ## helper functions: decode
end