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
    ["0.23.0"]="e8abf2109c015f2077cb6e23207c005c0b19d74bbfd78b113ed9645dc573fed16f94f7be31c6bb58f27cd21d61a76d40363b443d46ef9982f98498fa4f6a3e57"
    ["0.22.7"]="ddfa71081f635b762b129557ddead5f19f9af9f68a872facc86eab6d4a4f7a0cbb275e082362795f8f9c0d0b630a8f65276e53fab2f8f4a52fd2405394d1cbcb"
    ["0.22.6"]="a8c997fe504d64470cc21896c4a57273212bea5d6885641863f1030b44b2878029bec8dafcdce873e540771be60f471be25f1324a658e5e7759e7b8ab2764940"
    ["0.22.5"]="e4368e7db1a35b6e05eed409283543464d51460e6b99923938f880277c4d9dce6cd3f7c004134f013e4286916c5da61769a6e9e597eb691f70269aefb48c2432"
    ["0.22.4"]="4c225685ead65c6bca1e7b3077da8e5d345f8283848b8a2f32f00903f10249fb7a62263b75bbbd3b016440d43dc0da3a5785b48ff3b0ededa520beb1496f03d9"
    ["0.22.3"]="419ab92a8f5ce7fef79392192cdf2930f691d02a24248d44d4d8677abb107da03935a54db2883b514e09c3baa1690cb2437f5cf4d25c5db35ab0226de7670df6"
    ["0.22.2"]="eb3b010cedde1f8c65cda947e7daed5a8f55ed6f0c113a8a153e578420e43d2b47065b99edde0815dcaf4b27426ba8d2e01a19aa564a045278a45f5dea045d3b"
    ["0.22.1"]="ec1f2459bfa1d6f2ba306541fc2f18fc0b391d44532008193ce11e02e15094c6cf5b41be0b70d2e5919e6c5f5cd1b3c962817e9fc4f698016d8a8431c5da1b46"
    ["0.22.0"]="8c8210f6f69ef28f8bdb4fb16d4fa819ba1316473fdf3ea1bc487ef24faae3d068837482b632364bd65b5698ab82e685acf7a2e737774bc166724b724642bd26"
    ["0.21.0"]="81b6057b5e0b52d560683c3db32de02b1b280ac7b415f5bec5995d8b283f108402b5af721813c9379664bed718e1a6e599c010f6c2c5f85e9a25fcfa604f49a4"
    ["0.20.2"]="c3611f156cb6c4817977fc6e0762f0a70da8e7cae4b50563beae5a2e527cc4533427480810af12fe90a8277f946e0386610c220ca9b831c02949863931563667"
    ["0.20.1"]="61a964bb8049ec9b683575ea9c44cc273353bc618d0809a12e5f0d4aaa422c5bc1e97b1206b80417d74da0d32c6e86f1ade69c9bdebf86b2b56b950658df95c8"
    ["0.20.0"]="de10a45c8a8fc64ec4c7844d75744c832ceb99831260648b4d2a10e76cf8129caec1f6350a3400e87cdf70df8dfc39d39b348978f7d5e09aacd7fd5f731fe069"
    ["0.19.9"]="4c0939551c22bf61095d57585c4fc967b3abac597f05842c506c5a34ad90220a35177c3c93b407a5b2dc48d08011c209b7da0ae4af0d9b703aa0604611d1372f"
    ["0.19.8"]="e56a13b52a5cf91b355a23e73847d77fa1cc74d3d0d472320e3f4fb330c97b5f160b4ed478a4713c871d2fb0855cc05b5e5ed26c6add15b10bd896422aec4e17"
    ["0.19.7"]="d50484a217e4545048446237bf6ef87072fd3bd5d7567e85e1e64ef6ca989ef745812c9b1c46ff092f03fea806b1d761a6c56ba177f91cc78747411443ee045c"
    ["0.19.6"]="0d9cbc600b57edfab484fe20d4dc95a2781837df540f542d12497e67bc265a4ee9ace1004500b7c3f018f9e395198acede2fcdb3b4be1f9b0739b183ac5367e1"
    ["0.19.5"]="52ac3901bc72b311914c19c341b08021e0353e76e8ab1fc1d883b9e524d9095f4b644c5dc302081c695467763db01b32984b7156e4146917c2a901377ebebe63"
    ["0.19.4"]="3615de3e5aec73a8c49eb4df7d832a378ab922d6052c1c9c185da4a7838f42720a4270a3da3bbfa520fc61c4da8ca9a43128e864acb30452b4852556a31589bb"
    ["0.19.3"]="8d0f5e44531f6b0e9b55c1d4fc945262633f2ef87db214aae9dd14aef73efd1fb46e2b3746a0d67436a03fc53f48c871719ae02fbb0960bfc3a8153c0dcfe1f4"
    ["0.19.2"]="fc8cc21a3bc2d7b086d62d944c263d8991e35917b6c4837b8d8bffe7170d346da54a923d515dc835ace2a1b9efbe714c97113b245d14a4f68737b607d0b29dce"
    ["0.19.1"]="bf8768adbd8c8baf0c5767334cc7c3f59da089e79615a029546f34504aff3325f242d47f15f46babcc7b56e0326473019b4e263e5ef782940022d60c9149789b"
    ["0.19.0"]="321d851b52c0ad6089412a517e594e29fb39780122ef27f6e53c8d4edaf1339df109f03ee33e1ad6949b975ca157b8f879bf1b93ba3a694819be994c82eb03af"
    ["0.18.1"]="d2efd3fc265a421f77702985c634d3eb9d8a7cc1dd9265c101238ac1db5893688235335a2e5c9e3fd92c2eebac66c772a50117b756351c216827887d500618b4"
    ["0.18.0"]="84d724ad401bab3a9fca0982ba03a2a8a581d7dd1ad75149ed1698f646da75490d638e43c9c26215ed953f99aa02a91dd7d1c9a562f822e644f5e52147f7d009"
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