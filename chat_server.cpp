#include "chat_server.h"
#include "client_handler.h" // 包含具体定义
#include "json_utils.h"
#include <iostream>

ChatServer::ChatServer() {}
ChatServer::~ChatServer() {}

void ChatServer::on_client_connected(ClientHandler* client) {
    std::lock_guard<std::mutex> lock(clients_mutex_);
    clients_[client->get_handle()] = client;
    std::cout << "New client connected: " << client->get_handle() << std::endl;
}

void ChatServer::on_client_disconnected(Handle fd) {
    std::string username;
    {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        auto it = clients_.find(fd);
        if (it != clients_.end()) {
            username = it->second->get_username();
            // 注意：handler 的内存由 Reactor 负责释放
            clients_.erase(it);
            std::cout << "Client disconnected: " << fd << " (" << username << ")" << std::endl;
        }
    }
    if (!username.empty()) {
        broadcast_user_list();
        std::string notification = JsonUtils::create_system_notification(username + " has left the chat.");
        broadcast_message(notification);
    }
}

void ChatServer::process_message(ClientHandler* client, const std::string& json_data) {
    std::string msg_type = JsonUtils::get_string_value(json_data, "type");
    if (msg_type.empty()) return;

    if (msg_type == "login_request") {
        std::string username = JsonUtils::get_string_value(json_data, "username");
        if (!username.empty()) {
            client->set_username(username);
            std::cout << "Client " << client->get_handle() << " logged in as " << username << std::endl;
            broadcast_user_list();
            std::string welcome_msg = JsonUtils::create_system_notification("Welcome " + username + " to the chat room!");
            broadcast_message(welcome_msg);
        }
    }
    else if (msg_type == "chat_message") {
        std::string text = JsonUtils::get_string_value(json_data, "text");
        std::string sender_name = client->get_username();
        if (!text.empty() && !sender_name.empty()) {
            std::string chat_msg = JsonUtils::create_chat_message(sender_name, text);
            broadcast_message(chat_msg);
        }
    }
}

void ChatServer::broadcast_message(const std::string& json_message, Handle except_fd) {
    std::lock_guard<std::mutex> lock(clients_mutex_);
    for (auto const& [fd, handler] : clients_) {
        if (fd != except_fd) {
            handler->send_message(json_message);
        }
    }
}

void ChatServer::broadcast_user_list() {
    std::lock_guard<std::mutex> lock(clients_mutex_);
    std::vector<std::string> usernames;
    for (auto const& [fd, handler] : clients_) {
        if (!handler->get_username().empty()) {
            usernames.push_back(handler->get_username());
        }
    }
    std::string user_list_msg = JsonUtils::create_user_list_update(usernames);
    broadcast_message(user_list_msg);
}