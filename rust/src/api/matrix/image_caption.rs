use matrix_sdk::ruma::events::room::message::RoomMessageEventContent;
use serde_json::Value;

pub(super) const SHARED_CAPTION_KEY: &str = "moe.aks.matter.shared_caption";

/// Keep a standard caption on the final image while every image carries the
/// description used by Matter's gallery. Both fields remain inside the event
/// content, so encrypted rooms protect them along with the media metadata.
pub(super) fn with_captions(
    content: RoomMessageEventContent,
    caption: Option<&str>,
    shared_caption: Option<&str>,
) -> Result<Value, String> {
    let mut content = serde_json::to_value(content).map_err(|error| error.to_string())?;
    if let Some(caption) = nonempty_caption(caption) {
        content["filename"] = content["body"].clone();
        content["body"] = Value::String(caption.to_owned());
    }
    if let Some(caption) = nonempty_caption(shared_caption) {
        content[SHARED_CAPTION_KEY] = Value::String(caption.to_owned());
    }
    Ok(content)
}

pub(super) fn shared_caption(event: &Value) -> Option<String> {
    let content = event.get("content")?;
    nonempty_caption(content.get(SHARED_CAPTION_KEY)?.as_str()).map(str::to_owned)
}

fn nonempty_caption(caption: Option<&str>) -> Option<&str> {
    caption.map(str::trim).filter(|caption| !caption.is_empty())
}
