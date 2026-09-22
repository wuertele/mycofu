{ lib
, stdenv
, fetchFromGitHub
, python3
, autoPatchelfHook
, zlib
}:

let
  version = "1.0.75";
  meshcentralRev = "MeshCentral_v${version}";
  meshcentralHash = "sha256-ElWzDaa3A0WCjdDLC33ctxh1VukRs5FXxL67xUH/8Dc=";
in
stdenv.mkDerivation {
  pname = "meshcmd";
  inherit version;

  src = fetchFromGitHub {
    owner = "Ylianst";
    repo = "MeshCentral";
    rev = meshcentralRev;
    hash = meshcentralHash;
  };

  nativeBuildInputs = [
    autoPatchelfHook
    python3
  ];

  buildInputs = [
    stdenv.cc.cc.lib
    zlib
  ];

  dontConfigure = true;
  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin" "$out/share/doc/meshcmd" "$out/share/meshcmd"

    python3 <<'PY'
import os
import pathlib

src = pathlib.Path(".")
out = pathlib.Path(os.environ["out"]) / "bin" / "meshcmd"
payload_out = pathlib.Path(os.environ["out"]) / "share" / "meshcmd" / "meshcmd.js"

def escape_code_string(data):
    table = {
        ord("'"): "\\'",
        ord('"'): '\\"',
        ord("\\"): "\\\\",
        8: "\\b",
        12: "\\f",
        10: "\\n",
        13: "\\r",
        9: "\\t",
    }
    escaped = []
    for byte in data:
        if byte in table:
            escaped.append(table[byte])
        elif 32 <= byte <= 127:
            escaped.append(chr(byte))
    return "".join(escaped)

parts = ["var addedModules = [];\r\n"]
for module in sorted((src / "agents" / "modules_meshcmd").glob("*.js")):
    name = module.name[:-3]
    if name.endswith(".min"):
        name = name[:-4]
    parts.append(
        'try { addModule("' + name + '", "' +
        escape_code_string(module.read_bytes()) +
        '"); addedModules.push("' + name + '"); } catch (ex) { }\r\n'
    )

meshcmd = (src / "agents" / "meshcmd.js").read_text()
meshcmd = meshcmd.replace("'***Mesh*Cmd*Version***'", "'${version}'")
parts.append(meshcmd)

payload = "".join(parts).encode()
out.write_bytes((src / "agents" / "meshagent_x86-64").read_bytes())
out.chmod(0o755)
payload_out.write_bytes(payload)
PY

    install -Dm0644 LICENSE "$out/share/doc/meshcmd/LICENSE"

    runHook postInstall
  '';

  postFixup = ''
    python3 <<'PY'
import os
import pathlib
import struct

out = pathlib.Path(os.environ["out"])
binary = out / "bin" / "meshcmd"
payload = (out / "share" / "meshcmd" / "meshcmd.js").read_bytes()
guid = bytes.fromhex("B996015880544A19B7F7E9BE44914C18")

# MeshCentral's upstream streamExeWithJavaScript appends JS, a big-endian
# payload length, then the JavaScript GUID. The append must happen after
# autoPatchelf rewrites the Linux ELF interpreter; otherwise patchelf can
# discard the non-ELF trailer and the stub starts as MeshAgent, not MeshCmd.
with binary.open("ab") as fh:
    fh.write(payload)
    fh.write(struct.pack(">I", len(payload)))
    fh.write(guid)
PY
  '';

  passthru = {
    inherit meshcentralRev meshcentralHash;
  };

  meta = {
    description = "MeshCentral command-line tool with Intel AMT IDER support";
    homepage = "https://github.com/Ylianst/MeshCentral";
    license = lib.licenses.asl20;
    mainProgram = "meshcmd";
    platforms = [ "x86_64-linux" ];
    sourceProvenance = with lib.sourceTypes; [
      fromSource
      binaryNativeCode
    ];
  };
}
