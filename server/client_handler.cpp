#include "client_handler.h"
#include <iostream>
#include <unistd.h>
#include <cerrno>
#include <string.h>

ClientHandler::ClientHandler(Handle fd, Reactor* r, ChatServer* server)
    : sock_fd_(fd), reactor_(r), chat_server_(server) {
    chat_server_->on_client_connected(this);
}

ClientHandler::~ClientHandler() {}

Handle ClientHandler::get_handle() const {
    return sock_fd_;
}

void ClientHandler::handle_read() {
    char buffer[4096];
    while (true) {
        ssize_t n = recv(sock_fd_, buffer, sizeof(buffer), 0);
        if (n > 0) {
            read_buf_.append(buffer, n);
        }
        else if (n == 0) {
            handle_error();
            return;
        }
        else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            perror("recv error");
            handle_error();
            return;
        }
    }

    size_t pos;
    while ((pos = read_buf_.find('\n')) != std::string::npos) {
        std::string json_data = read_buf_.substr(0, pos);
        read_buf_.erase(0, pos + 1);
        if (!json_data.empty()) {
            thread_pool->enqueue([this, json_data]() {
                this->chat_server_->process_message(this, json_data);
                });
        }
    }
}

void ClientHandler::send_message(const std::string& json_message) {
    std::string message_with_newline = json_message + "\n";
    {
        std::lock_guard<std::mutex> lock(write_buf_mutex_);
        write_buf_ += message_with_newline;
    }
    // 正确做法：修改事件，在 READ 的基础上增加 WRITE
    reactor_->modify(get_handle(), static_cast<Event>(READ | WRITE));
}

void ClientHandler::handle_write() {
    std::string to_send;
    {
        std::lock_guard<std::mutex> lock(write_buf_mutex_);
        if (write_buf_.empty()) {
            // 正确做法：写完了，修改事件，移除 WRITE，只保留 READ
            reactor_->modify(get_handle(), READ);
            return;
        }
        to_send.swap(write_buf_);
    }

    size_t sent_bytes = 0;
    while (sent_bytes < to_send.size()) {
        ssize_t n = send(sock_fd_, to_send.c_str() + sent_bytes, to_send.size() - sent_bytes, 0);
        if (n > 0) {
            sent_bytes += n;
        }
        else {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            perror("send error");
            handle_error();
            return;
        }
    }

    if (sent_bytes < to_send.size()) {
        std::lock_guard<std::mutex> lock(write_buf_mutex_);
        write_buf_.insert(0, to_send.substr(sent_bytes));
    }
    else {
        // 正确做法：全部写完了，同样修改回只读事件
        reactor_->modify(get_handle(), READ);
    }
}

void ClientHandler::handle_error() {

    reactor_->remove(get_handle());
}

void ClientHandler::handle_close() {
    chat_server_->on_client_disconnected(sock_fd_);
    // 注意：这里的 delete this; 将由 reactor_impl 中的 remove 逻辑调用
    // 为了安全，我们只关闭socket
    close(sock_fd_);
}