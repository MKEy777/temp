#include "sock_handler.h"
#include <chrono>
#include <cerrno>
#include <string.h>
#include <iostream>

SockHandler::SockHandler(Handle fd, Reactor* r) : sock_fd(fd), reactor(r) {}

SockHandler::~SockHandler() { close(sock_fd); }

Handle SockHandler::get_handle() const { return sock_fd; }

void SockHandler::handle_read() {
    int n = recv(sock_fd, read_buf, sizeof(read_buf), 0);
    if (n > 0) {
        std::string data(read_buf, n);
        thread_pool->enqueue([this, data]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            std::string processed = data + " [processed]";
            {
                std::lock_guard<std::mutex> lock(buf_mutex);
                write_buf += processed;
            }
            reactor->modify(sock_fd, WRITE);
            });
    }
    else if (n == 0) { // 客户端正常关闭
        handle_error();
    }
    else { // n < 0，发生错误
        // 在非阻塞模式下，EAGAIN 或 EWOULDBLOCK 表示没有数据可读，是正常情况
        if (errno != EAGAIN && errno != EWOULDBLOCK) {
            perror("recv error");
            handle_error();
        }
    }
}

void SockHandler::handle_write() {
    std::string to_send;
    {
        std::lock_guard<std::mutex> lock(buf_mutex);
        if (write_buf.empty()) return;
        to_send = write_buf;
        write_buf.clear();
    }
    send(sock_fd, to_send.c_str(), to_send.size(), 0);
    reactor->modify(sock_fd, READ); // 写完后，继续监听读事件
}

void SockHandler::handle_error() { reactor->remove(sock_fd); }
void SockHandler::handle_close() {}