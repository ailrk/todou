{ mkDerivation, aeson, amazonka, amazonka-s3, base
, base64-bytestring, bytestring, conduit, containers, cookie
, criterion, cryptohash-sha256, cryptonite, deepseq, directory
, file-embed, filepath, hspec, http-types, jwt, lib, lucid
, network-uri, psqueues, QuickCheck, req, scotty, sqlite-simple
, string-interpolate, temporary, text, time, unliftio, wai
, wai-extra, warp, zlib
}:
mkDerivation {
  pname = "todou";
  version = "1.0.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson amazonka amazonka-s3 base base64-bytestring bytestring
    conduit containers cookie cryptohash-sha256 cryptonite deepseq
    directory file-embed filepath http-types jwt lucid network-uri
    psqueues scotty string-interpolate text time wai wai-extra warp
    zlib
  ];
  executableHaskellDepends = [ base ];
  testHaskellDepends = [
    aeson base base64-bytestring bytestring containers filepath hspec
    QuickCheck sqlite-simple temporary text time zlib
  ];
  benchmarkHaskellDepends = [
    aeson base bytestring containers criterion deepseq http-types req
    text time unliftio
  ];
  license = lib.licenses.bsd3;
  mainProgram = "todou";
}
