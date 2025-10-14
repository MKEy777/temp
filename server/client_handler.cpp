#include "client_handler.h"
#include "json_utils.h"
#include <iostream>
#include <unistd.h>
#include <cerrno>
#include <string.h>

ClientHandler::ClientHandler(Handle fd, Reactor* r, ChatServer* server)
    : sock_fd_(fd), reactor_(r), chat_server_(server) {
    chat_server_->on_client_connected(this);
}
ClientHandler::~ClientHandler() {}

Handle ClientHandler::get_handle() const { return sock_fd_; }

void ClientHandler::handle_read() {
    char buffer[4096];
    ssize_t n = recv(sock_fd_, buffer, sizeof(buffer) - 1, 0);
    if (n > 0) {
        buffer[n] = '\0';
        read_buf_.append(buffer, n);
        std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): Received " << n << " bytes. Current buffer: \"" << read_buf_ << "\"" << std::endl;
    }
    else if (n == 0) {
        handle_error();
        return;
    }
    else {
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            perror("recv error");
            handle_error();
        }
    }
    size_t pos;
    while ((pos = read_buf_.find('\n')) != std::string::npos) {
        std::string json_data = read_buf_.substr(0, pos);
        read_buf_.erase(0, pos + 1);
        std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): Parsed a complete message: \"" << json_data << "\". Enqueuing to thread pool." << std::endl;
        if (!json_data.empty()) {
            thread_pool->enqueue([this, json_data]() {
                std::cout << "[DEBUG] ThreadPool: Worker thread is now processing message for handle " << this->get_handle() << "." << std::endl;
                this->chat_server_->process_message(this->get_handle(), json_data);
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
    // --- 调试信息 ---
    std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): Queued message to write_buf. Modifying epoll for WRITE event." << std::endl;
    reactor_->modify(get_handle(), static_cast<Event>(READ | WRITE));
}

void ClientHandler::handle_write() {
    // --- 调试信息 ---
    std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): handle_write triggered." << std::endl;
    std::string to_send;
    {
        std::lock_guard<std::mutex> lock(write_buf_mutex_);
        if (write_buf_.empty()) {
            std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): write_buf is empty. Modifying epoll back to READ only." << std::endl;
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
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // --- 调试信息 ---
                std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): send() returned EAGAIN/EWOULDBLOCK. Kernel buffer is full." << std::endl;
                break;
            }
            perror("send error");
            handle_error();
            return;
        }
    }

    // --- 调试信息 ---
    std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): Sent " << sent_bytes << " bytes out of " << to_send.size() << "." << std::endl;

    if (sent_bytes < to_send.size()) {
        std::lock_guard<std::mutex> lock(write_buf_mutex_);
        write_buf_.insert(0, to_send.substr(sent_bytes));
    }
    else {
        std::cout << "[DEBUG] ClientHandler(" << sock_fd_ << "): All data sent. Modifying epoll back to READ only." << std::endl;
        reactor_->modify(get_handle(), READ);
    }
}

void ClientHandler::handle_error() {
    reactor_->remove(get_handle());
}

void ClientHandler::handle_close() {
    chat_server_->on_client_disconnected(sock_fd_);
    close(sock_fd_);
}

void ClientHandler::post_connection_established() {
    chat_server_->on_client_connected(this);
}