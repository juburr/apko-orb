#!/bin/bash

set -e

# Ensure CircleCI environment variables can be passed in as orb parameters
INSTALL_PATH=$(circleci env subst "${PARAM_INSTALL_PATH}")
VERIFY_CHECKSUMS="${PARAM_VERIFY_CHECKSUMS}"
VERSION=$(circleci env subst "${PARAM_VERSION}")

# Print command arguments for debugging purposes.
echo "Running Apko installer..."
echo "  INSTALL_PATH: ${INSTALL_PATH}"
echo "  VERIFY_CHECKSUMS: ${VERIFY_CHECKSUMS}"
echo "  VERSION: ${VERSION}"

# Lookup table of sha512 checksums for different versions of apko
declare -A sha512sums
sha512sums=(
    ["0.17.0"]="049122bd578156c4c7fa2b883896e74e5f4fe2616c959ca8611bb44434740759fa8bffb60d31cabbdce67e3c3655d2c121c1a21ba8647ed0f888bfa7dbc08dc4"
    ["0.16.0"]="a1a375b72dd605ed7afe231eb6469ae66c16ab5a96469bb5c9e18769b8a299b876236f32f6f5dd66fefe3b1b54eb72c98d357a599fad25a8739440b41996c859"
    ["0.15.0"]="14e6905b2077e3e606beb1c0d660fb4447e89999bff974648939a5f0619e9b74a9206ffb08958037937c87ae81829d72df73468bb02e8dddb4238d83825b3795"
    ["0.14.9"]="7c3ea4ad65401a92194b359be7aa2ebbc93d7d0a9c5c1a1e3cec0a92608f9782775a678dd2f6c8a6c56538ca2cd9c38688cbcd8a0f1d9e2cad8c739f4f56babf"
    ["0.14.8"]="b0fa52194e327bf8026707ffd1daa3d387d968f36aa642d73ce27083ac04daf9cd7d53c3b72316fba5d5e9b2b9d66244514fbbc655fd47c96bdcefd824a6d0fc"
    ["0.14.7"]="576aae40265978594896b3e2c438e9c76ce08e96e793217df105581be2a4da55d5b94ec27af20d2aa04f165f10a6c35d4cd070fb94b35aaf80c72e5f924937b6"
    ["0.14.6"]="12706241294c9a85d207d0fb92de295f9ae4791593bf596cb2ccf8d578f3c5926bed3107383f2315c9184b2aa9e9d820f08cfb186113b5f47d63e11029fab411"
    ["0.14.5"]="3fefc73c48132cb3cac454837d04ba3bcec7cda1beb3e449cc018aad2a1ce41630cdbd0418e585e7c7b103e87d2ff4386039021bf48cf7e73fb8a35cd167eef8"
    ["0.14.4"]="7a95d2293d6f60901071997441e3e4ff179fbdbc5d815be93570536a8a13f167802b9e721ae6f87f03bab28ad97e3cdd08926864e8b86feb833541bd88aa28dd"
    ["0.14.3"]="42558b0372ee2d86749c3e31527064b75b84f66c807063be33aeef616840b25485a312a5d510325337a258b06d73dd307feadb0dca031f22c8950c91e9ae2f33"
    ["0.14.2"]="f9ffcd8586c64e935ab680fd3f6e5ff9c266c21d57f6692f84b0b9ee8c7d72a0c3e8c689cfe1f6ba381eba806f9ac47feb73b186f9267dfbcdfc4e900faa7798"
    ["0.14.1"]="17d87ba7527809140ae037214862aa9e7926775c9a0cd687ebe19eb653712d28f8e27e1733888f787af183ce1e30cda828c60bc90ceb785c9c2b8b4ee2b50f33"
    ["0.14.0"]="ad0efcc1b643186efe31781eaaf308120727bae507354e4b4b43738be3ef16fd12ee202eec07e559441761ed64cb4e4b26e615dc49095c7771dea6fb8ea6fe4c"
    ["0.13.3"]="c29aad55166a88d8060a46418bf7001466e8d4068122821433d048be59ab6afb005da8f9c8a59775e56526f296c7c7ef5cd994170f834da4e1c766f6f45a9b59"
    ["0.13.2"]="a3a39f4e013936e7952a791447f4fee4d09921f32dc56303c4e64b1d315285152db7e7c4917b14cdf878c3c1e713836a3c4ccd3ae638863ddf3603baad89c5e1"
    ["0.13.1"]="e192d3993829e1f4fcf2adcc846bf103d7824536fca3e05b6953e150910828551c6ade5a3391cb823f38c4eff0b384527f4e2f87e8a0b45f5ae4c0ca3b4b54c4"
    ["0.13.0"]="0be138cb76c0d79cf1734add89d83a7eb4843645cad1428392dca8ca25730231df3904a7675aa63c86fe938c7479d607baad941972de06b5dacd74ba4d548ccd"
    ["0.12.0"]="73cf247ea780690a5c391f818f3cd3eebc2fabdce081f9d9fe753659b342a3a4cf02e3c27815d9ebf88b1792aa5ec6143b3b9dc40df65ce0b6b9d1ec3c611366"
    ["0.11.3"]="643382d5bdbb5bb9ecb09291965d5eb393b1f912fd50718449e36cd5cd6a4d8b6d1391f18fbb1e74c478562772e1d9bfbdf31d166ca1d3dfa8975ff9ecd66cd9"
    ["0.11.2"]="4302e77b554d09eacdd4e7d29f9aac273c2d1d0c1e5f985a6bac9fa4746f8a9088af9a57af37c87a0d47efcf08e3d907e53b5e746a6aee30f34d339f916b8e3d"
    ["0.11.1"]="c34da8239d78d18746fd0920769efd47064e74abeed243d876bf39f039c37bf3d36830f55dbf2aa74736c4f55589b9c5aa2cdf1af0885459c31891545c0b39b7"
    ["0.11.0"]="d65021f4a1391976bedf69405b3003a7b50c6121bfd205298c04ccfb4a24e2da9682a23da28396be6bb2e8d06e8c62476a0fff1a78e81796fbe24cdf30a2de48"
    ["0.10.0"]="d6496856752fc15cfc6201ce3c7ec3a04ab2d8aa28a2f979c4009085291d22164ae949b216ef86cc17b914fe37dfb35e8acb016c609f29cd76d1e08c7931c5e2"
    ["0.9.0"]="7eb8b05f55d4cf4d407742723b6eb1f0e58f00895bdf925d23f633eee760a258412abccaf24c023e9a9b32c47ed748943b2a8d36bed8b19da42c2d599cfb12f0"
    ["0.8.0"]="4904c8ac6721d09ff57e7e2454183369e368184b598829c56cf4dcea3272899102e941cc0ab796b6c72f929f7d61d7d4239a6488d4a89d4b6259274b0723cdfa"
    ["0.7.3"]="ca5a3285bb8eb67f1468b919f9afd25d48909e140fdc4ff534d96595f75945762261d065db48278ae2024fdd5f70ec96e3bfaa6239b7b0eb2447dcf8d24003ab"
    ["0.7.2"]="9a2afdae861833e022bdb38e4b1fdae7936dd512c1b612ee251e5ea1342cf0d5bcfbb8d1238f31776d0606c13fc13c96185ad215f8c1d55e5e51a0811311f3e4"
    ["0.7.1"]="2ac861e82e021215b842534861459a20398b5b5a1c6e55be2d846c899d047bd2a666338b6ddb9253bea4ca6597a022a833f86aebfe827612324e2ea19b1c516c"
    ["0.7.0"]="6e1f28b54212d8fcb4678ed12a9e092630d16f280eec02f1eb71302a8b652901ceaf87ea6b6fb024c456f23f8507dd43c59e9818360c04db23ab1def7e7b7e34"
    ["0.6.1"]="453d4c03721d0245e6643f57975fff68141caf12ddd99e53bb0af553e8153970e245d08cb2c9fe7a6a5f14326ea33b0bf17d65e143d53f4e8ac197cd439ee7ab"
    ["0.6.0"]="7d85948e1d03682fc3572230319d9935db568f688a27aae4cb415268207239d9695e215f8b7b6444a82f4c5ab4a233dd44403051f71d03fdb35a54456ef04380"
    ["0.5.0"]="15f14553291437597afed430ff0116fe40bd4ca853b1e9ac4b492ce29fec20573339d44e2adfb465cddd978a8a65d8b583e8534a15d4644927b90db588647356"
    ["0.4.0"]="bf375af26d209db018b811f2540ffef315bf71495ccf084d5f4cf00a874d46ba02a06c2bb9d8a49aad766beea1002c1fa42fc5101e3cbef350522b4350907946"
    ["0.3.3"]="3286661f73a01396c671c9dfb8882318ab35503628e8075437749478d179ee38d18c7a04676ec59374c05723bbf8ce6057ad92873e98e500220a29d0befb9076"
    ["0.3.2"]="52c0176df8715bdcd8cb26324a11599726cce25195defc37fb4520c123d86b636f059ff15019bccd809b432b77b9b50b6e6b11a112c7e8c3d54af8cc17ccd3fa"
    ["0.3.1"]="b9a991345044e1620cf149a51ab70c742e18e6bc1a159b09a915a6149d5c54b3279a65e177384032d049fd87799222dbe2757d9aff5dd73771fb272f515051ef"
    ["0.3.0"]="4362d6511a4e78e4b49113b7ac6c5853bc35e17a0ed04c69859f460add45141e9cb7be536d09968d9cde289ace63cb7ea75afcee2fe520a9b87ffaeebab6872b"
    ["0.2.2"]="81b31307e381c4b33fc304bcefca478b3a55b7bf201fc4019f7eaf2665ec470f0bb629242e9cf7a35af5bf3db554a023b733508c872577c12f13e1389ff13731"
    ["0.2.1"]="324d8db2bb5f6124fce1535d1ec84a7cd08e76965ae4a9a8d440df10cffb09b682135c4e19b591b99679d79251ff4b38764d6895449882f7a3f7225ce91caa3b"
    ["0.2.0"]="245d5e632840e410a8119d0affa0db4a0a248aff0522e7a610d03d9e187074f0811406b785754e403c04c96cec325e717ec0711107e2c159d618b52e8fc332b0"
    ["0.1.2"]="2af4fef466c537277bbdba24119eae91e53fb3f886021d0a0c70aea400bf35bbe783f269b8035889ae51ba2781b57e5bcdd1178ca3a524bb34e5f030271ff313"
    ["0.1.1"]="fcc7c70832ceba5d21c35f6088f7f06f0a0426ca0c5878c24cd778828e30f7cfe7b43ec8b2c4a4b4b999d7aa370cc2420cecef2efde8c263379c58e69af0cf55"
    ["0.1"]="8cdc9427cb397d00a5dc031cdecb6d8e68f06ce701a29c766a361d00b420995a1e83f8dbe17d8fc9960a7e6545693d8a85d3140b5e4cfc5b8c21decbc7e9b29b"
)

# Verfies that the SHA-512 checksum of a file matches what was in the lookup table
verify_checksum() {
    local file=$1
    local expected_checksum=$2

    actual_checksum=$(sha512sum "${file}" | awk '{ print $1 }')

    echo "Verifying checksum for ${file}..."
    echo "  Actual: ${actual_checksum}"
    echo "  Expected: ${expected_checksum}"

    if [[ "${actual_checksum}" != "${expected_checksum}" ]]; then
        echo "ERROR: Checksum verification failed!"
        exit 1
    fi

    echo "Checksum verification passed!"
}

# Check if the apko tar file was in the CircleCI cache.
# Cache restoration is handled in install.yml
if [[ -f apko.tar.gz ]]; then
    tar zxvf apko.tar.gz "apko_${VERSION}_linux_amd64/apko" --strip 1
fi

# If there was no cache hit, go ahead and re-download the binary.
if [[ ! -f apko ]]; then
    wget "https://github.com/chainguard-dev/apko/releases/download/v${VERSION}/apko_${VERSION}_linux_amd64.tar.gz" -O apko.tar.gz
    tar zxvf apko.tar.gz "apko_${VERSION}_linux_amd64/apko" --strip 1
fi

# An apko binary should exist at this point, regardless of whether it was obtained
# through cache or re-downloaded. First verify its integrity.
if [[ "${VERIFY_CHECKSUMS}" != "false" ]]; then
    EXPECTED_CHECKSUM=${sha512sums[${VERSION}]}
    if [[ -n "${EXPECTED_CHECKSUM}" ]]; then
        # If the version is in the table, verify the checksum
        verify_checksum "apko" "${EXPECTED_CHECKSUM}"
    else
        # If the version is not in the table, this means that a new version of Apko
        # was released but this orb hasn't been updated yet to include its checksum in
        # the lookup table. Allow developers to configure if they want this to result in
        # a hard error, via "strict mode" (recommended), or to allow execution for versions
        # not directly specified in the above lookup table.
        if [[ "${VERIFY_CHECKSUMS}" == "known_versions" ]]; then
            echo "WARN: No checksum available for version ${VERSION}, but strict mode is not enabled."
            echo "WARN: Either upgrade this orb, submit a PR with the new checksum."
            echo "WARN: Skipping checksum verification..."
        else
            echo "ERROR: No checksum available for version ${VERSION} and strict mode is enabled."
            echo "ERROR: Either upgrade this orb, submit a PR with the new checksum, or set 'verify_checksums' to 'known_versions'."
            exit 1
        fi
    fi
else
    echo "WARN: Checksum validation is disabled. This is not recommended. Skipping..."
fi

# After verifying integrity, install it by moving it to an appropriate bin
# directory and marking it as executable. If your pipeline throws an error
# here, you may want to choose an INSTALL_PATH that doesn't require sudo access,
# so this orb can avoid any root actions.
mv apko "${INSTALL_PATH}/apko"
chmod +x "${INSTALL_PATH}/apko"