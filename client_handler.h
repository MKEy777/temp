#pragma once
#include "event_handler.h"
#include "reactor.h"
#include "chat_server.h"
#include "thread_pool.h"
#include <string>
#include <mutex>

extern ThreadPool* thread_pool;

class ClientHandler : public EventHandler {
public:
    ClientHandler(Handle fd, Reactor* r, ChatServer* server);
    ~ClientHandler();

    Handle get_handle() const override;
    void handle_read() override;
    void handle_write() override;
    void handle_error() override;
    void handle_close() override; 

    void send_message(const std::string& json_message);
    std::string get_username() const { return username_; }
    void set_username(const std::string& name) { username_ = name; }

private:
    Handle sock_fd_;
    Reactor* reactor_;
    ChatServer* chat_server_;
    std::string read_buf_;
    std::string write_buf_;
    std::mutex write_buf_mutex_;
    std::string username_;
};