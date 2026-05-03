{ mkDerivation, aeson, amazonka, amazonka-s3, base
, base64-bytestring, bytestring, conduit, containers, cookie
, cryptohash-sha256, cryptonite, directory, file-embed, filepath
, hspec, http-types, jwt, lib, lucid, network-uri, QuickCheck
, scotty, sqlite-simple, string-interpolate, temporary, text, time
, wai, wai-extra, warp, zlib
}:
mkDerivation {
  pname = "todou";
  version = "1.0.0.0";
  src = ./.;
  isLibrary = true;
  isExecutable = true;
  libraryHaskellDepends = [
    aeson amazonka amazonka-s3 base base64-bytestring bytestring
    conduit containers cookie cryptohash-sha256 cryptonite directory
    file-embed filepath http-types jwt lucid network-uri scotty
    string-interpolate text time wai wai-extra warp zlib
  ];
  executableHaskellDepends = [ base ];
  testHaskellDepends = [
    aeson base base64-bytestring bytestring containers filepath hspec
    QuickCheck sqlite-simple temporary text time zlib
  ];
  license = lib.licenses.bsd3;
  mainProgram = "todou";
}
