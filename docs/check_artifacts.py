"""Offline release-shape, compiler, ABI and opcode checks. Run after forge build."""

import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def read(path):
    return json.loads((ROOT / path).read_text())


manifest = read("launch.json")
assert set(manifest) == {"kind", "hook", "token", "pool", "notes"}
assert manifest["kind"] == "univ4_hook"
assert manifest["hook"] == {
    "contract": "MedallionHook",
    "constructorArgs": ["0xE03A1074c86CFeDd5C142C4F04F1a1536e203543"],
    "permissions": ["beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"],
}
assert manifest["token"] == {
    "contract": "FareToken", "name": "Fare for Medallion 447", "symbol": "FARE447", "decimals": 18
}
assert manifest["pool"] == {
    "pairedCurrency": "0x0000000000000000000000000000000000000000",
    "fee": 3000, "tickSpacing": 60, "initialPrice": "79228162514264337593543950336000",
}
assert len(manifest["notes"]) <= 4000
assert "0x70c6C4fcaAb11151FCEDb32eaaC3431547193A0a" in manifest["notes"]

for name, expected_args in (("FareToken", []), ("MedallionHook", ["address"])):
    artifact = read(f"out/{name}.sol/{name}.json")
    constructors = [x for x in artifact["abi"] if x["type"] == "constructor"]
    assert len(constructors) == 1
    assert [x["type"] for x in constructors[0]["inputs"]] == expected_args
    methods = {x.get("name") for x in artifact["abi"] if x["type"] == "function"}
    assert not methods.intersection({
        "owner", "admin", "mint", "pause", "unpause", "upgradeTo", "initialize", "beforeInitialize",
        "sweep", "transferOwnership", "payCreator",
    })
    assert artifact["abi"] == read(f"docs/abi/{name}.json")
    metadata = artifact["metadata"]
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    assert metadata["compiler"]["version"].startswith("0.8.26+")
    settings = metadata["settings"]
    assert settings["evmVersion"] == "cancun"
    assert settings["optimizer"] == {"enabled": True, "runs": 200}
    assert not settings.get("viaIR", False)
    assert settings["metadata"]["bytecodeHash"] == "none"
    assert settings["metadata"]["appendCBOR"] is False
    runtime = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(runtime) <= 24576
    print(f"{name}: ABI and constructor match; runtime {len(runtime)} bytes; compiler settings match")

assert read("lib/v4-core/package.json")["version"] == "1.0.2"

count = 0
for path in sorted((ROOT / "out").glob("*/*.json")):
    artifact = json.loads(path.read_text())
    has_code = False
    for field in ("bytecode", "deployedBytecode"):
        hex_code = artifact.get(field, {}).get("object", "")
        code = bytes.fromhex(hex_code.removeprefix("0x"))
        if not code:
            continue
        has_code = True
        offset = 0
        while offset < len(code):
            op = code[offset]
            assert op not in (0xF2, 0xF4, 0xFF), f"{path}: {field} forbidden {op:#x} at {offset}"
            offset += 1 + (op - 0x5F if 0x60 <= op <= 0x7F else 0)
    count += has_code

assert count > 0
print(f"{count} compiled contracts: no F2/F4/FF instructions in creation or runtime opcode walks")
print("Manifest field shape, literal constructor, permissions, notes, pool and ABI checks passed")
