# Pure-RGC crypto vector test: SHA-2, HMAC, HKDF (RFC 5869), AES/GCM (FIPS-197, NIST SP 800-38D),
# ChaCha20-Poly1305 (RFC 8439), X25519 (RFC 7748), P-256/ECDSA, RSA PKCS#1 v1.5/PSS and ASN.1/PEM.
import aes
import asn1
import bin
import bytes
import chacha20poly1305 as chacha
import hkdf
import hmac
import p256
import pkey
import sha2
import x25519

def hx(s: str) -> Bytes {
    return bin.from_hex(s)
}

def hex_is(b: @Bytes, want: str) -> bool {
    return bin.to_hex(@b) == want
}

def main() {
    abc = bytes.bytes_from_str("abc")

    d = sha2.sha256(@abc)
    print("sha256_abc", hex_is(@d,
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"))
    empty = bytes.bytes_new(0)
    d = sha2.sha256(@empty)
    print("sha256_empty", hex_is(@d,
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
    long_msg = bytes.bytes_from_str(
        "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
    d = sha2.sha256(@long_msg)
    print("sha256_long", hex_is(@d,
        "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"))
    d = sha2.sha384(@abc)
    print("sha384_abc", hex_is(@d,
        "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed" +
        "8086072ba1e7cc2358baeca134c825a7"))
    d = sha2.sha512(@abc)
    print("sha512_abc", hex_is(@d,
        "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" +
        "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"))

    # RFC 4231 test cases 1 and 2.
    key20 = hx("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    hi = bytes.bytes_from_str("Hi There")
    d = hmac.sha256(@key20, @hi)
    print("hmac_sha256_1", hex_is(@d,
        "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"))
    jefe = bytes.bytes_from_str("Jefe")
    question = bytes.bytes_from_str("what do ya want for nothing?")
    d = hmac.sha256(@jefe, @question)
    print("hmac_sha256_2", hex_is(@d,
        "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"))
    d = hmac.sha384(@key20, @hi)
    print("hmac_sha384_1", hex_is(@d,
        "afd03944d84895626b0825f4ab46907f15f9dadbe4101ec682aa034c7cebc59c" +
        "faea9ea9076ede7f4af152e8b2fa9cb6"))

    # RFC 5869 test case 1.
    ikm = hx("0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b0b")
    salt = hx("000102030405060708090a0b0c")
    info = hx("f0f1f2f3f4f5f6f7f8f9")
    prk = hkdf.extract_sha256(@salt, @ikm)
    print("hkdf_prk", hex_is(@prk,
        "077709362c2e32df0ddc3f0dc47bba6390b6c73bb50f9c3122ec844ad7c2b3e5"))
    okm = hkdf.expand_sha256(@prk, @info, 42)
    print("hkdf_okm", hex_is(@okm,
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf" +
        "34007208d5b887185865"))

    # FIPS-197 AES block vectors.
    pt = hx("00112233445566778899aabbccddeeff")
    k128 = hx("000102030405060708090a0b0c0d0e0f")
    c128 = aes.aes_new(@k128)
    out = aes.aes_encrypt_block(@c128, @pt)
    print("aes128_block", hex_is(@out, "69c4e0d86a7b0430d8cdb78070b4c55a"))
    k256 = hx("000102030405060708090a0b0c0d0e0f" +
              "101112131415161718191a1b1c1d1e1f")
    c256 = aes.aes_new(@k256)
    out = aes.aes_encrypt_block(@c256, @pt)
    print("aes256_block", hex_is(@out, "8ea2b7ca516745bfeafc49904b496089"))

    # NIST GCM test cases 1 and 2.
    zkey = hx("00000000000000000000000000000000")
    znonce = hx("000000000000000000000000")
    sealed = aes.gcm_seal(@zkey, @znonce, @empty, @empty)
    print("gcm_empty", hex_is(@sealed, "58e2fccefa7e3061367f1d57a4e7455a"))
    zblock = hx("00000000000000000000000000000000")
    sealed = aes.gcm_seal(@zkey, @znonce, @empty, @zblock)
    print("gcm_block", hex_is(@sealed,
        "0388dace60b6a392f328c2b971b2fe78ab6e47d42cec13bdf53a67b21257bddf"))
    opened = aes.gcm_open(@zkey, @znonce, @empty, @sealed)
    odata = opened.data
    print("gcm_open", opened.ok and hex_is(@odata,
        "00000000000000000000000000000000"))
    sealed.set(0, sealed.get(0) ^ 1)
    bad = aes.gcm_open(@zkey, @znonce, @empty, @sealed)
    print("gcm_tamper", bad.ok)

    # RFC 8439 section 2.8.2 AEAD vector.
    ckey = hx("808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9f")
    cnonce = hx("070000004041424344454647")
    caad = hx("50515253c0c1c2c3c4c5c6c7")
    msg = bytes.bytes_from_str("Ladies and Gentlemen of the class of '99: If I " +
                               "could offer you only one tip for the future, " +
                               "sunscreen would be it.")
    csealed = chacha.seal(@ckey, @cnonce, @caad, @msg)
    print("chacha_seal", hex_is(@csealed,
        "d31a8d34648e60db7b86afbc53ef7ec2a4aded51296e08fea9e2b5a736ee62d6" +
        "3dbea45e8ca9671282fafb69da92728b1a71de0a9e060b2905d6a5b67ecd3b36" +
        "92ddbd7f2d778b8c9803aee328091b58fab324e4fad675945585808b4831d7bc" +
        "3ff4def08e4b7a9de576d26586cec64b6116" +
        "1ae10b594f09e26a7e902ecbd0600691"))
    copen = chacha.open(@ckey, @cnonce, @caad, @csealed)
    want = bin.to_hex(@msg)
    cdata = copen.data
    print("chacha_open", copen.ok and hex_is(@cdata, want))
    csealed.set(0, csealed.get(0) ^ 1)
    cbad = chacha.open(@ckey, @cnonce, @caad, @csealed)
    print("chacha_tamper", cbad.ok)

    # RFC 7748 section 5.2 Diffie-Hellman vectors.
    apriv = hx("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    bpriv = hx("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    apub = x25519.base_public(@apriv)
    bpub = x25519.base_public(@bpriv)
    print("x25519_alice_pub", hex_is(@apub,
        "8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a"))
    print("x25519_bob_pub", hex_is(@bpub,
        "de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f"))
    s1 = x25519.shared_secret(@apriv, @bpub)
    s2 = x25519.shared_secret(@bpriv, @apub)
    print("x25519_shared",
        hex_is(@s1, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742") and
        hex_is(@s2, "4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742"))

    # P-256: generator multiples and ECDH.
    d1 = hx("0000000000000000000000000000000000000000000000000000000000000001")
    d2 = hx("0000000000000000000000000000000000000000000000000000000000000002")
    g1 = p256.base_public(@d1)
    g2 = p256.base_public(@d2)
    print("p256_generator", hex_is(@g1,
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"))
    print("p256_2g", hex_is(@g2,
        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978" +
        "07775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"))
    shared = p256.shared_secret(@d1, @g2)
    print("p256_shared", hex_is(@shared,
        "7cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc47669978"))
    kp = p256.keypair()
    kpriv = kp.private_key
    kpub = kp.public_key
    ka = p256.shared_secret(@kpriv, @g2)
    kb = p256.shared_secret(@d2, @kpub)
    print("p256_keypair", kpriv.len == 32 and kpub.len == 65 and
        hex_is(@ka, bin.to_hex(@kb)))

    # ECDSA P-256/P-384 signatures made with openssl over "rgc crypto vector message".
    vec = bytes.bytes_from_str("rgc crypto vector message")
    ecder = hx(
        "3059301306072a8648ce3d020106082a8648ce3d030107034200" +
        "042a46f70b29d3e179ac02b68e5a863b8f927e0f3f77c799ec13c82f31184c7b" +
        "339090f16acb36f50f410063c4d68ae34c129c07aa803a05bcc61a5d9e37c8e8ae")
    ecpub = pkey.parse_spki(@ecder)
    eckey = ecpub.key
    ecsig = hx("3046022100b0a6ce4eeb48cfc2468413c1d0f9c1e8be875e925f20fa257b1b13a8" +
               "691bb4d7022100f334876d1da279dc21f52d99a0e6b47f41ccaaa4968897d8ac7" +
               "62fc0ec3509ac")
    ecdigest = sha2.sha256(@vec)
    print("ecdsa_p256_verify", ecpub.ok and
        pkey.verify(@eckey, "ecdsa_secp256r1_sha256", @ecdigest, @ecsig))
    ecdigest.set(0, ecdigest.get(0) ^ 1)
    print("ecdsa_p256_tamper",
        pkey.verify(@eckey, "ecdsa_secp256r1_sha256", @ecdigest, @ecsig))

    e384der = hx(
        "3076301006072a8648ce3d020106052b81040022036200" +
        "0425bc9e8d13a150108f2ee0b8dc128a4a25d653cb9069ac3c6848651d5554d4" +
        "07ba395990178106fd1c430b201f6571f6b83ea949f50a17cf47ad86d56492a7" +
        "cdf55e3e9312c5e861126e62bc0dd0b5f49e41394a120cd37c31a4e81b2b4017d8")
    ec384pub = pkey.parse_spki(@e384der)
    ec384key = ec384pub.key
    ec384sig = hx("3065023100f0c39fb5e7830854ec353da62dae254033a52f7aa643dd07b9deae84" +
                  "2a684b44a086741afd6f7f7c6615e2fbf96177c70230219995a158ec0351402dd" +
                  "3e632178c31f4254f4f27635f535eef23f564438fc639b715c718ca3a1d476f78" +
                  "087f0b2b92")
    d384 = sha2.sha384(@vec)
    print("ecdsa_p384_verify", ec384pub.ok and
        pkey.verify(@ec384key, "ecdsa_secp384r1_sha384", @d384, @ec384sig))

    # RSA PKCS#1 v1.5 and PSS signatures over the same message.
    rsader = hx(
        "30820122300d06092a864886f70d01010105000382010f003082010a0282010100" +
        "ca6499ce9b86de3941d4f78913ddb23e34273ffabf29424003241303964f7f979" +
        "a007545bd65a12e7d211e0193443942b91695fc818d1ecefae0e372afb1321d5d" +
        "3058b203a2858f602c348a58213b7c185506743dc8d08d0b9f86ea23d63aa0eb" +
        "321b56c30d0ca3816d4e99bd3d39ed5ca6a86f78c50a3b9cddf1e7211b637fa2" +
        "6f8dfc124a275eb0b00f80c9a5e252635c47f396dbd6ee52642ace9715b79b38" +
        "836e6170c4307f4b1ee8cfaeddec0fc10fde0e7025ecd3809692755a2d4c611e" +
        "a2949e419a585cf8ed7cacd7eaa7945cf82be38d00f32923a3bd4f509a309fda" +
        "d21f92705bfec526f44e55b6a35c35cdd631dc0d5bbcfc4bd12dd97357d87102" +
        "03010001")
    rsapub = pkey.parse_spki(@rsader)
    rkey = rsapub.key
    rdigest = sha2.sha256(@vec)
    pkcs1sig = hx(
        "255aea5c3d954d247eb7f59d8cd5bc0ec991daa3d180f1c3c702546789970ea7" +
        "1517173e292af6a64683686f3425311b8fd2d93936da1b8e21a36f28736d06fc" +
        "9732abf37ae07fc2e7ac9aa643760331ce50c75baadb9d2dc7c7efacb95d7f55" +
        "f03ba41be63ab4e46c40de5b5f40096650d9b664ca4e09ef7a23bce7dd6ac0b3" +
        "16c4de71fc4f8cb8d8d958ce65889377b69b37e6f504204fbb61de4962f9cd58" +
        "8d97c125f327889ef67811d06c94b0bb4051f7e5d87ed76fd9a55b22dbe4c992" +
        "21735d4b97f4b0742723add0378326a6d78a4261c2896da10c2e8704c344513d" +
        "7af0e303bcfbe9ece374a8c8b2b7d708b7e5d8662e59eeb5f9220bd6f2c5c0cd")
    psssig = hx(
        "258d0ec6791c3d686013077b9d964620c6a1b674ff7732378192128a7fcd7bba" +
        "2382cec32d7f3a46eb7d9db8766c1917b9ef76857416f328f64cf64835f76879" +
        "9584008898656ce327b67a08999a6d39dfe3c92abf3c74a84bc75038145b7317" +
        "f69bc6f4c3873b49ddd237212e1d87729ee5a724ea673499f226c68d9f9908e0" +
        "7eae620d2c4f6be83f011f0ab8498f8c083a7c60c643f64b156d326fafdc0275" +
        "ae180ce6e447343434d438ed892a87cd777e137c3a055eedb5799b2e1b623aa8" +
        "0188059cff6fcc38d50caef585629fd88c88c95c4b01fe14824afa76770d5814" +
        "2c8ab72d9c0550dea5d6597ac2f601f3554d32a5210057654e14814a4b45749b")
    print("rsa_pkcs1_verify", rsapub.ok and
        pkey.verify(@rkey, "rsa_pkcs1_sha256", @rdigest, @pkcs1sig))
    print("rsa_pss_verify", rsapub.ok and
        pkey.verify(@rkey, "rsa_pss_rsae_sha256", @rdigest, @psssig))
    print("rsa_wrong_scheme",
        pkey.verify(@rkey, "rsa_pkcs1_sha256", @rdigest, @psssig))

    # ASN.1 DER and PEM decoding.
    intder = hx("020105")
    tint = asn1.der_next(@intder, 0)
    content = asn1.der_content(@intder, @tint)
    print("asn1_int", tint.ok and tint.tag == 2 and tint.len == 1 and
        content.get(0) == 5)
    oidder = hx("06092a864886f70d01010b")
    toid = asn1.der_next(@oidder, 0)
    oid = asn1.der_oid_str(@oidder, @toid)
    print("asn1_oid", toid.ok and oid == "1.2.840.113549.1.1.11")
    seqder = hx("3003020107")
    tseq = asn1.der_next(@seqder, 0)
    tinner = asn1.der_next(@seqder, tseq.start)
    icontent = asn1.der_content(@seqder, @tinner)
    print("asn1_seq", tseq.ok and tseq.tag == 48 and tinner.ok and
        icontent.get(0) == 7)
    b64 = asn1.base64_decode("aGVsbG8=")
    print("base64", hex_is(@b64, "68656c6c6f"))
    pemtext = bytes.bytes_from_str("-----BEGIN TEST-----\naGVsbG8=\n-----END TEST-----\n")
    block = asn1.pem_next(@pemtext, 0)
    pder = block.der
    print("pem", block.ok and block.label == "TEST" and
        hex_is(@pder, "68656c6c6f"))
}
