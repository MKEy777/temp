#include "chat_server.h"
#include "client_handler.h"
#include "json_utils.h"
#include <iostream>
#include <vector>

// ... ���캯��, on_client_connected, on_client_disconnected, process_message ���ֲ��� ...
ChatServer::ChatServer(Reactor* sub_reactor) : sub_reactor_(sub_reactor) {}
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
void ChatServer::process_message(Handle client_handle, const std::string& json_data) {
    std::cout << "[DEBUG] ChatServer: process_message called in worker thread for handle " << client_handle << "." << std::endl;
    std::string msg_type = JsonUtils::get_string_value(json_data, "type");
    if (msg_type.empty()) return;

    if (msg_type == "login_request") {
        std::string username = JsonUtils::get_string_value(json_data, "username");
        if (!username.empty()) {
            std::cout << "[DEBUG] ChatServer: Login request for user '" << username << "'. Queuing task to Reactor." << std::endl;
            sub_reactor_->queue_in_loop([this, client_handle, username]() {
                std::cout << "[DEBUG] Reactor Task: Now executing login for user '" << username << "' in Reactor thread." << std::endl;
                auto it = clients_.find(client_handle);
                if (it != clients_.end()) {
                    ClientHandler* handler = it->second;
                    handler->set_username(username);
                    std::cout << "Client " << handler->get_handle() << " logged in as " << username << std::endl;
                    broadcast_user_list();
                    std::string welcome_msg = JsonUtils::create_system_notification("Welcome " + username + " to the chat room!");
                    broadcast_message(welcome_msg);
                }
                else {
                    std::cout << "[ERROR] Reactor Task: Handler for handle " << client_handle << " not found!" << std::endl;
                }
                });
        }
    }
    else if (msg_type == "chat_message") {
        std::string text = JsonUtils::get_string_value(json_data, "text");
        sub_reactor_->queue_in_loop([this, client_handle, text]() {
            auto it = clients_.find(client_handle);
            if (it != clients_.end()) {
                std::string sender_name = it->second->get_username();
                if (!text.empty() && !sender_name.empty()) {
                    std::string chat_msg = JsonUtils::create_chat_message(sender_name, text);
                    broadcast_message(chat_msg);
                }
            }
            });
    }
}

// broadcast_message ���ֲ��䣬���������
void ChatServer::broadcast_message(const std::string& json_message, Handle except_fd) {
    std::cout << "\n[DEBUG] BROADCAST: Starting broadcast..." << std::flush;
    std::cout << "\n[DEBUG] BROADCAST: Message is: " << json_message << std::flush;

    std::cout << "\n[DEBUG] BROADCAST: Attempting to lock clients_mutex..." << std::flush;
    std::lock_guard<std::mutex> lock(clients_mutex_);
    std::cout << "\n[DEBUG] BROADCAST: Lock acquired. Map size is " << clients_.size() << "." << std::flush;

    if (clients_.empty()) {
        std::cout << "\n[DEBUG] BROADCAST: No clients to broadcast to. Exiting." << std::flush;
        return;
    }

    std::cout << "\n[DEBUG] BROADCAST: Starting loop..." << std::flush;
    for (auto const& pair : clients_) {
        Handle fd = pair.first;
        ClientHandler* handler = pair.second;

        std::cout << "\n[DEBUG] BROADCAST:  - Considering FD " << fd << "." << std::flush;
        if (handler == nullptr) {
            std::cout << "\n[DEBUG] BROADCAST:  - ERROR: Handler for FD " << fd << " is NULL!" << std::flush;
            continue;
        }

        if (fd != except_fd) {
            std::cout << "\n[DEBUG] BROADCAST:  - Sending to FD " << fd << "..." << std::flush;
            handler->send_message(json_message);
            std::cout << "\n[DEBUG] BROADCAST:  - Call to send_message for FD " << fd << " returned." << std::flush;
        }
        else {
            std::cout << "\n[DEBUG] BROADCAST:  - Skipping FD " << fd << " (exception)." << std::flush;
        }
    }
    std::cout << "\n[DEBUG] BROADCAST: Loop finished." << std::endl;
}

// --- �����޸����Ƴ�������� ---
void ChatServer::broadcast_user_list() {
    // std::lock_guard<std::mutex> lock(clients_mutex_); // <--- �Ƴ���һ��

    std::vector<std::string> usernames;
    // ��Ϊ����������������� broadcast_message ֮ǰ�����ã�
    // ���Ҷ���ͬһ�� sub-reactor �̵߳������У�
    // ����������ʱ������Ҳ�ǰ�ȫ�ġ�
    // �����Ͻ��������Ǵ���һ����ʱ���û��б�����
    {
        std::lock_guard<std::mutex> lock(clients_mutex_);
        for (auto const& [fd, handler] : clients_) {
            if (handler && !handler->get_username().empty()) {
                usernames.push_back(handler->get_username());
            }
        }
    }

    if (usernames.empty()) return;

    std::string user_list_msg = JsonUtils::create_user_list_update(usernames);
    std::cout << "[DEBUG] ChatServer: Broadcasting user list." << std::endl;
    broadcast_message(user_list_msg);
}