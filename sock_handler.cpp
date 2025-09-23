#include "sock_handler.h"
#include <winsock2.h>
#include <chrono>

SockHandler::SockHandler(Handle fd, Reactor* r) : sock_fd(fd), reactor(r) {}

SockHandler::~SockHandler() { closesocket(sock_fd); }

Handle SockHandler::get_handle() const { return sock_fd; }

void SockHandler::handle_read() {
    int n = recv(sock_fd, read_buf, sizeof(read_buf), 0);
    if (n > 0) {
        std::string data(read_buf, n);
        thread_pool->enqueue([this, data]() {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));  // Ä£ÄâºÄÊ±
            std::string processed = data + " [processed]";
            {
                std::lock_guard<std::mutex> lock(buf_mutex);
                write_buf += processed;
            }
            reactor->modify(sock_fd, WRITE);
            });
    }
    else if (n == 0 || (n == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK)) {
        handle_error();
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
    reactor->modify(sock_fd, READ);
}

void SockHandler::handle_error() { reactor->remove(sock_fd); }

void SockHandler::handle_close() {}