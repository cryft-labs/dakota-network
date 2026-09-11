# SPDX-License-Identifier: Apache-2.0
# Reuse only genuine Rust FULL results for identical, live-checked genesis runtime.
# Address import never sets verification flags. Only Blockscout's normal publisher
# consumes the verified result, after equality and provenance checks below.
Logger.configure(level: :error)
{:ok, _} = Application.ensure_all_started(:explorer)

defmodule DakotaGenesisVerification do
  alias Explorer.Chain
  alias Explorer.Chain.{Address, SmartContract}
  alias Explorer.SmartContract.Solidity.{Publisher, Verifier}

  def assert!(true, _), do: :ok
  def assert!(_, message), do: raise(message)
  def sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  def json(path), do: path |> File.read!() |> Jason.decode!()
  def save(path, value) do
    File.write!(path <> ".tmp", Jason.encode!(value))
    File.rename!(path <> ".tmp", path)
  end

  def rpc(request) do
    response = HTTPoison.post!("http://100.111.69.1:8547/", Jason.encode!(request),
      [{"Content-Type", "application/json"}], timeout: 15_000, recv_timeout: 60_000)
    assert!(response.status_code == 200, "Archive RPC HTTP failure")
    Jason.decode!(response.body)
  end
  def call(method, params) do
    response = rpc(%{jsonrpc: "2.0", id: 1, method: method, params: params})
    assert!(!Map.has_key?(response, "error"), "Archive RPC error: " <> method)
    Map.fetch!(response, "result")
  end

  def address_hash(address) do
    {:ok, hash} = Chain.string_to_address_hash(address)
    hash
  end

  def validate_existing!(contract, build) do
    assert!(!contract.partially_verified, "Existing source is only a partial match")
    assert!(contract.name == build["contract_name"] && contract.file_path == build["source_path"], "Existing target mismatch")
    assert!(String.trim_leading(contract.compiler_version, "v") == String.trim_leading(build["compiler_version"], "v"), "Existing compiler mismatch")
    assert!(to_string(contract.license_type) == build["license_type"], "Existing license mismatch")
  end

  def main do
    dir = System.fetch_env!("DAKOTA_VERIFICATION_DIR")
    data = json(Path.join(dir, "genesis-input.json"))
    assert!(Explorer.mode() == :api, "Worker must use API mode without the indexer")
    assert!(call("eth_chainId", []) == "0x1b6b7", "Wrong chain ID")
    assert!(call("eth_getBlockByNumber", ["0x0", false])["hash"] == data["genesis_block_hash"], "Wrong genesis hash")
    head = call("eth_blockNumber", [])
    header = call("eth_getBlockByNumber", [head, false])
    offset = String.to_integer(System.get_env("DAKOTA_VERIFICATION_OFFSET", "0"))
    limit = String.to_integer(System.get_env("DAKOTA_VERIFICATION_LIMIT", "32433"))
    dry = System.get_env("DAKOTA_VERIFICATION_DRY_RUN", "false") == "true"
    rows = data["addresses"] |> Enum.drop(offset) |> Enum.take(limit)
    save(Path.join(dir, "progress.json"), %{checked: 0, total: length(rows), offset: offset, dry_run: dry,
      block: head, source_commit: data["source_commit"], completed: false})
    cache = Map.new(data["builds"], fn {name, build} ->
      for {file, expected} <- build["file_sha256"] do
        assert!(sha(File.read!(Path.join(dir, name <> "/" <> file))) == expected, "Artifact hash mismatch")
      end
      input_text = File.read!(Path.join(dir, name <> "/standard-input.json"))
      input = Jason.decode!(input_text)
      metadata = json(Path.join(dir, name <> "/metadata.json"))
      runtime = String.trim(File.read!(Path.join(dir, name <> "/runtime-bytecode.txt")))
      abi = json(Path.join(dir, name <> "/abi.json"))
      assert!(metadata["sources"][build["source_path"]]["license"] == build["spdx_license"], "SPDX mismatch")
      assert!(map_size(metadata["settings"]["compilationTarget"]) == 1, "Ambiguous compiler target")
      assert!(metadata["settings"]["compilationTarget"][build["source_path"]] == build["contract_name"], "Wrong compilation target")
      assert!(call("eth_getCode", [build["reference_address"], head]) == runtime, "Reference live runtime mismatch")
      params = %{"address_hash" => build["reference_address"], "compiler_version" => build["compiler_version"],
        "name" => build["contract_name"], "license_type" => build["license_type"], "constructor_arguments" => "", "autodetect_constructor_args" => "false"}
      {:ok, source} = Verifier.evaluate_authenticity_via_standard_json_input(build["reference_address"], params, input_text)
      assert!(source["matchType"] == "FULL", "Rust verifier did not produce FULL match")
      assert!(source["contractName"] == build["contract_name"] && source["fileName"] == build["source_path"], "Verifier target mismatch")
      assert!(String.trim_leading(source["compilerVersion"], "v") == String.trim_leading(build["compiler_version"], "v"), "Verifier compiler mismatch")
      assert!(source["constructorArguments"] in [nil, "", "0x"], "Genesis cannot have constructor arguments")
      assert!(Jason.decode!(source["abi"]) == abi, "Verifier ABI mismatch")
      assert!(source["sourceFiles"] == Map.new(input["sources"], fn {k, v} -> {k, v["content"]} end), "Verifier source bytes mismatch")
      assert!(map_size(build["immutable_references"]) == 0, "Cached genesis verification cannot reuse immutables")
      save(Path.join(dir, "rust-result-" <> name <> ".json"), source)
      {name, %{build: build, runtime: runtime, source: source, source_sha256: sha(Jason.encode!(source)), params: params}}
    end)
    log = Path.join(dir, if(dry, do: "dry-run.jsonl", else: "verified.jsonl"))
    Enum.chunk_every(rows, 20) |> Enum.with_index() |> Enum.each(fn {batch, batch_index} ->
      request = Enum.with_index(batch) |> Enum.map(fn {row, i} ->
        %{jsonrpc: "2.0", id: i, method: "eth_getCode", params: [row["address"], head]}
      end)
      response = rpc(request)
      assert!(is_list(response) && length(response) == length(batch), "Incomplete RPC batch")
      by_id = Map.new(response, &{&1["id"], &1})
      assert!(map_size(by_id) == length(batch), "Duplicate RPC batch response IDs")
      Enum.with_index(batch) |> Enum.each(fn {row, i} ->
        c = Map.fetch!(cache, row["artifact_alias"])
        returned = Map.fetch!(by_id, i)
        assert!(!Map.has_key?(returned, "error") && returned["result"] == c.runtime, "Live code mismatch at " <> row["address"])
      end)
      if !dry do
        # The only address fields imported are hash/code. Conflict handling preserves
        # existing records; code mismatch is fatal, never silently overwritten.
        params = Enum.map(batch, fn row ->
          c = Map.fetch!(cache, row["artifact_alias"])
          hash = address_hash(row["address"])
          existing = Explorer.Repo.get(Address, hash)
          if existing && existing.contract_code, do: assert!(to_string(existing.contract_code) == c.runtime, "Existing indexed runtime differs")
          %{hash: hash, contract_code: c.runtime}
        end)
        {:ok, _} = Chain.import(%{addresses: %{params: params, on_conflict: :nothing}})
        Enum.each(batch, fn row ->
          c = Map.fetch!(cache, row["artifact_alias"])
          hash = address_hash(row["address"])
          indexed = Explorer.Repo.get!(Address, hash)
          # Existing null code may be filled through the normal address pipeline.
          if is_nil(indexed.contract_code) do
            {:ok, _} = Chain.import(%{addresses: %{params: [%{hash: hash, contract_code: c.runtime}],
              on_conflict: {:replace, [:contract_code, :updated_at]}, fields_to_update: [:contract_code]}})
          end
          assert!(to_string(Explorer.Repo.get!(Address, hash).contract_code) == c.runtime, "Indexed code does not match live code")
          contract = Explorer.Repo.get(SmartContract, hash)
          if contract do
            validate_existing!(contract, c.build)
          else
            # This is the installed publisher's normal verifier-result path. The
            # genuine FULL response is reused solely for exact identical runtime,
            # source input, compiler settings and absent constructor/immutables.
            {:ok, contract} = Publisher.process_rust_verifier_response(c.source, row["address"], c.params, true, true, false)
            validate_existing!(contract, c.build)
          end
          assert!(SmartContract.verified_with_full_match?(hash), "Published source is not a full match")
          File.write!(log, Jason.encode!(%{address: row["address"], artifact_alias: row["artifact_alias"],
            state: "verified", method: "genuine_rust_full_result_reused_for_exact_live_genesis_runtime",
            license_type: c.build["license_type"], compiler_version: c.build["compiler_version"],
            source_path: c.build["source_path"], contract_name: c.build["contract_name"],
            runtime_sha256: sha(Base.decode16!(String.trim_leading(c.runtime, "0x"), case: :mixed)), verifier_result_sha256: c.source_sha256,
            checked_block: head, checked_block_hash: header["hash"], source_commit: data["source_commit"]}) <> "\n", [:append])
        end)
      end
      done = min((batch_index + 1) * 20, length(rows))
      progress = %{checked: done, total: length(rows), offset: offset, dry_run: dry, block: head,
        block_hash: header["hash"], source_commit: data["source_commit"], completed: done == length(rows)}
      save(Path.join(dir, "progress.json"), progress)
      if rem(batch_index, 25) == 0 || done == length(rows), do: IO.puts(Jason.encode!(progress))
    end)
  end
end
try do
  DakotaGenesisVerification.main()
rescue
  error ->
    message = Exception.message(error) |> String.replace(~r{postgres(?:ql)?://[^@\s]+@}, "postgresql://[REDACTED]@") |> String.slice(0, 2500)
    DakotaGenesisVerification.save(Path.join(System.fetch_env!("DAKOTA_VERIFICATION_DIR"), "failure.json"),
      %{error: message, type: inspect(error.__struct__), stack: Exception.format_stacktrace(Enum.take(__STACKTRACE__, 8))})
    reraise error, __STACKTRACE__
end
