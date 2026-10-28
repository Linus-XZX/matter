use std::error::Error;
use std::time::Instant;

/// Context retained across sending a request and reading its response body.
pub(crate) struct RequestDiagnostics {
    started: Instant,
    url: url::Url,
    pub(crate) stage: &'static str,
    pub(crate) status: Option<u16>,
}

impl RequestDiagnostics {
    pub(crate) fn new(url: url::Url) -> Self {
        Self {
            started: Instant::now(),
            url,
            stage: "send",
            status: None,
        }
    }

    pub(crate) fn context(&self) -> String {
        format!(
            "url={} stage={} elapsed_ms={} http_status={}",
            diagnostic_url(self.url.clone()),
            self.stage,
            self.started.elapsed().as_millis(),
            self.status
                .map_or_else(|| "none".to_owned(), |code| code.to_string()),
        )
    }

    pub(crate) fn failure<E: Error + 'static>(&self, error: &E) -> String {
        let mut chain = vec![sanitize_error_urls(&error.to_string())];
        let mut source = error.source();
        while let Some(cause) = source {
            chain.push(sanitize_error_urls(&cause.to_string()));
            source = cause.source();
        }
        format!(
            "{} error_type={} error_chain={}",
            self.context(),
            std::any::type_name::<E>(),
            chain.join(" -> "),
        )
    }
}

fn diagnostic_url(mut url: url::Url) -> String {
    let _ = url.set_username("");
    let _ = url.set_password(None);
    url.set_query(None);
    url.set_fragment(None);
    url.to_string()
}

/// Network errors can repeat a URL containing query credentials or userinfo.
/// Keep the endpoint, but never persist those URL components in diagnostics.
fn sanitize_error_urls(message: &str) -> String {
    let mut remaining = message;
    let mut result = String::new();
    while let Some(start) = remaining
        .find("https://")
        .into_iter()
        .chain(remaining.find("http://"))
        .min()
    {
        result.push_str(&remaining[..start]);
        remaining = &remaining[start..];
        let end = remaining
            .find(|c: char| c.is_whitespace() || matches!(c, '"' | '\'' | ')' | '}'))
            .unwrap_or(remaining.len());
        let raw_url = &remaining[..end];
        match url::Url::parse(raw_url) {
            Ok(url) => result.push_str(&diagnostic_url(url)),
            Err(_) => result.push_str("[invalid URL]"),
        }
        remaining = &remaining[end..];
    }
    result.push_str(remaining);
    result
}
