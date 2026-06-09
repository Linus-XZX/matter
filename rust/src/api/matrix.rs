use flutter_rust_bridge::frb;

#[frb]
pub enum ConnectionStatus {
    Connected,
    Connecting,
    Updating,
    Disconnected,
}

#[frb]
pub struct ChatRoom {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub last_message: String,
    pub last_message_time: String,
    pub unread_count: i32,
    pub is_pinned: bool,
    pub is_muted: bool,
}

#[frb]
pub struct Space {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
}

#[frb]
pub struct Contact {
    pub id: String,
    pub name: String,
    pub avatar_url: Option<String>,
    pub status: String,
}

#[frb(sync)]
pub fn get_connection_status() -> ConnectionStatus {
    // Mock: randomly return different statuses
    ConnectionStatus::Connected
}

#[frb]
pub async fn init_client() -> Result<(), String> {
    // Placeholder: will integrate matrix-rust-sdk later
    Ok(())
}

#[frb]
pub async fn get_chat_rooms() -> Result<Vec<ChatRoom>, String> {
    let rooms = vec![
        ChatRoom {
            id: "room_1".to_string(),
            name: "Flutter 开发者".to_string(),
            avatar_url: None,
            last_message: "新的 UI 看起来真不错 👍".to_string(),
            last_message_time: "14:32".to_string(),
            unread_count: 3,
            is_pinned: true,
            is_muted: false,
        },
        ChatRoom {
            id: "room_2".to_string(),
            name: "Rust 交流".to_string(),
            avatar_url: None,
            last_message: "async/await 在 FFI 里确实有点麻烦".to_string(),
            last_message_time: "12:05".to_string(),
            unread_count: 0,
            is_pinned: false,
            is_muted: false,
        },
        ChatRoom {
            id: "room_3".to_string(),
            name: "Matrix Protocol".to_string(),
            avatar_url: None,
            last_message: "你们试过新的 sliding sync 吗？".to_string(),
            last_message_time: "昨天".to_string(),
            unread_count: 12,
            is_pinned: false,
            is_muted: false,
        },
        ChatRoom {
            id: "room_4".to_string(),
            name: "设计讨论".to_string(),
            avatar_url: None,
            last_message: "Liquid glass 效果再克制一点会更好".to_string(),
            last_message_time: "昨天".to_string(),
            unread_count: 0,
            is_pinned: false,
            is_muted: true,
        },
        ChatRoom {
            id: "room_5".to_string(),
            name: "Matter 内部".to_string(),
            avatar_url: None,
            last_message: "UI 第一版快要完成了 🎉".to_string(),
            last_message_time: "周一".to_string(),
            unread_count: 1,
            is_pinned: true,
            is_muted: false,
        },
    ];
    Ok(rooms)
}

#[frb]
pub async fn get_spaces() -> Result<Vec<Space>, String> {
    let spaces = vec![
        Space {
            id: "all".to_string(),
            name: "全部".to_string(),
            avatar_url: None,
        },
        Space {
            id: "space_1".to_string(),
            name: "工作".to_string(),
            avatar_url: None,
        },
        Space {
            id: "space_2".to_string(),
            name: "兴趣".to_string(),
            avatar_url: None,
        },
        Space {
            id: "space_3".to_string(),
            name: "家庭".to_string(),
            avatar_url: None,
        },
    ];
    Ok(spaces)
}

#[frb]
pub enum MessageType {
    Text,
    Image,
}

#[frb]
pub struct ChatMessage {
    pub id: String,
    pub sender_id: String,
    pub sender_name: String,
    pub content: String,
    pub timestamp: String,
    pub is_me: bool,
    pub msg_type: MessageType,
    pub image_url: Option<String>,
}

#[frb]
pub async fn get_messages(room_id: String) -> Result<Vec<ChatMessage>, String> {
    let _ = room_id;
    let messages = vec![
        ChatMessage {
            id: "msg_1".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "嗨，Matter 的 UI 看起来真不错！".to_string(),
            timestamp: "14:20".to_string(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
        },
        ChatMessage {
            id: "msg_2".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "那个 Liquid Glass 效果用在导航栏上挺克制的，不会太抢注意力。".to_string(),
            timestamp: "14:21".to_string(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
        },
        ChatMessage {
            id: "msg_3".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "给你看看我拍的照片".to_string(),
            timestamp: "14:22".to_string(),
            is_me: false,
            msg_type: MessageType::Image,
            image_url: Some("https://picsum.photos/seed/matter1/800/600".to_string()),
        },
        ChatMessage {
            id: "msg_4".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "期待 😊 消息气泡打算怎么做？".to_string(),
            timestamp: "14:23".to_string(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
        },
        ChatMessage {
            id: "msg_5".to_string(),
            sender_id: "me".to_string(),
            sender_name: "我".to_string(),
            content: "谢谢！还在打磨细节，刚把底部导航的高度调了。".to_string(),
            timestamp: "14:25".to_string(),
            is_me: true,
            msg_type: MessageType::Text,
            image_url: None,
        },
        ChatMessage {
            id: "msg_6".to_string(),
            sender_id: "me".to_string(),
            sender_name: "我".to_string(),
            content: "左右分栏，自己的消息靠右，别人的靠左。圆角大一些，和整体风格统一。".to_string(),
            timestamp: "14:26".to_string(),
            is_me: true,
            msg_type: MessageType::Text,
            image_url: None,
        },
        ChatMessage {
            id: "msg_7".to_string(),
            sender_id: "me".to_string(),
            sender_name: "我".to_string(),
            content: "".to_string(),
            timestamp: "14:27".to_string(),
            is_me: true,
            msg_type: MessageType::Image,
            image_url: Some("https://picsum.photos/seed/matter2/800/600".to_string()),
        },
        ChatMessage {
            id: "msg_8".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "对，主要是避免低端机上掉帧。接下来要做聊天详情页了。".to_string(),
            timestamp: "14:28".to_string(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
        },
        ChatMessage {
            id: "msg_9".to_string(),
            sender_id: "user_1".to_string(),
            sender_name: "Alice".to_string(),
            content: "👍".to_string(),
            timestamp: "14:29".to_string(),
            is_me: false,
            msg_type: MessageType::Text,
            image_url: None,
        },
    ];
    Ok(messages)
}

#[frb]
pub async fn get_contacts() -> Result<Vec<Contact>, String> {
    let contacts = vec![
        Contact {
            id: "user_1".to_string(),
            name: "Alice".to_string(),
            avatar_url: None,
            status: "在线".to_string(),
        },
        Contact {
            id: "user_2".to_string(),
            name: "Bob".to_string(),
            avatar_url: None,
            status: "刚刚".to_string(),
        },
        Contact {
            id: "user_3".to_string(),
            name: "Charlie".to_string(),
            avatar_url: None,
            status: "离线".to_string(),
        },
        Contact {
            id: "user_4".to_string(),
            name: "Diana".to_string(),
            avatar_url: None,
            status: "在线".to_string(),
        },
        Contact {
            id: "user_5".to_string(),
            name: "Eve".to_string(),
            avatar_url: None,
            status: "30 分钟前".to_string(),
        },
    ];
    Ok(contacts)
}
