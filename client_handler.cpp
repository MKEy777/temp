#include "client_handler.h"
#include "thread_pool.h"
#include <iostream>
#include <unistd.h> 
#include <cerrno>
#include <string.h>

ClientHandler::ClientHandler(Handle fd, Reactor* r, ChatServer* server)
    : sock_fd_(fd), reactor_(r), chat_server_(server) {
    chat_server_->on_client_connected(this);
}

ClientHandler::~ClientHandler() {
    close(sock_fd_); // 在析构时关闭文件描述符
}

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
            handle_error(); // 客户端主动关闭
            return;
        }
        else { // n < 0
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                break; // 数据已读完
            }
            perror("recv error");
            handle_error();
            return;
        }
    }

    // 使用换行符 '\n' 分隔每个JSON消息
    size_t pos;
    while ((pos = read_buf_.find('\n')) != std::string::npos) {
        std::string json_data = read_buf_.substr(0, pos);
        read_buf_.erase(0, pos + 1);
        if (!json_data.empty()) {
            thread_pool->enqueue([this, data = std::move(json_data)]() {
                this->chat_server_->process_message(this, data);
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
    reactor_->regist(this, WRITE); // 通知 Reactor: 我有数据要写
}

void ClientHandler::handle_write() {
    std::string to_send;
    {
        std::lock_guard<std::mutex> lock(write_buf_mutex_);
        if (write_buf_.empty()) {
            reactor_->remove(sock_fd_);
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
        reactor_->remove(sock_fd_); // 写完了，移除写事件
    }
}

void ClientHandler::handle_error() {
    chat_server_->on_client_disconnected(sock_fd_);
    reactor_->remove(sock_fd_);
    // handler 的内存会由 reactor_impl 自动管理和释放
}

void ClientHandler::handle_close() {
    chat_server_->on_client_disconnected(sock_fd_);
    close(sock_fd_);
    delete this; // 自我销毁，释放内存
}