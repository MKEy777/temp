#pragma once
#include "event_demultiplexer.h" // For Handle type
#include <map>
#include <mutex>
#include <string>
#include <vector>

class ClientHandler; // Ç°ÏòÉùÃ÷

class ChatServer {
public:
    ChatServer();
    ~ChatServer();

    void on_client_connected(ClientHandler* client);
    void on_client_disconnected(Handle fd);
    void process_message(ClientHandler* client, const std::string& json_data);

private:
    void broadcast_message(const std::string& json_message, Handle except_fd = -1);
    void broadcast_user_list();

    std::map<Handle, ClientHandler*> clients_;
    std::mutex clients_mutex_;
};