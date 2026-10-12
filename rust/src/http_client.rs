use matrix_sdk::{Client, ClientBuilder};

pub(crate) fn matrix_client_builder() -> Result<ClientBuilder, String> {
    let builder = Client::builder();
    #[cfg(target_os = "android")]
    let builder = builder.http_client(
        android_http_client()
            .map_err(|error| format!("Failed to create Android HTTP client: {error}"))?,
    );
    Ok(builder)
}

#[cfg(target_os = "android")]
fn android_http_client() -> Result<reqwest::Client, reqwest::Error> {
    // Preserve Matrix SDK 0.18's Android workaround for platform-verifier issue
    // #221: certificates without OCSP URLs can be incorrectly marked revoked.
    // SDK 0.19 removed the workaround. WebPKI verifies the chain, hostname and
    // validity without requiring the platform verifier's JNI initialization.
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
    let tls = rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth();

    reqwest::Client::builder()
        .tls_backend_preconfigured(tls)
        .user_agent("matrix-rust-sdk")
        .min_tls_version(reqwest::tls::Version::TLS_1_2)
        .timeout(std::time::Duration::from_secs(30))
        .build()
}
