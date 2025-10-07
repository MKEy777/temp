#include "sock_handler.h"
#include <chrono>
#include <cerrno>
#include <string.h>
#include <iostream>
#include <cstdio>
#include <string>

SockHandler::SockHandler(Handle fd, Reactor* r) : sock_fd(fd), reactor(r) {}

SockHandler::~SockHandler() {
    close(sock_fd);
}

Handle SockHandler::get_handle() const {
    return sock_fd;
}

void SockHandler::handle_read() {
    std::cout << "handle_read() called for fd " << sock_fd << std::endl;
    std::string received_data;
    char read_buf[1024]; // 局部变量

    // 边缘触发(ET)模式下，必须循环读取，直到缓冲区数据被读完
    while (true) {
        size_t n = recv(sock_fd, read_buf, sizeof(read_buf), 0);

        if (n > 0) {
            // 将读取到的数据追加到 received_data
            received_data.append(read_buf, n);
        }
        else if (n == 0) {
            // 客户端正常关闭连接
            std::cout << "Client closed connection on fd " << sock_fd << std::endl;
            handle_error();
            return; // 结束处理
        }
        else { // n < 0
            // 在非阻塞模式下，EAGAIN 或 EWOULDBLOCK 表示数据已全部读取完毕
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::cout << "All data read for fd " << sock_fd << ". Total " << received_data.length() << " bytes." << std::endl;
                break; // 退出循环
            }
            else {
                // 其他错误，调用错误处理
                perror("recv error");
                handle_error();
                return; // 结束处理
            }
        }
    }

    // 只有在确实收到了数据时，才投递任务到线程池
    if (!received_data.empty()) {
        thread_pool->enqueue([this, data = std::move(received_data)]() {
            // 模拟业务处理
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            std::string processed = data + " [processed by epoll]";

            {
                std::lock_guard<std::mutex> lock(buf_mutex);
                write_buf += processed;
                std::cout << "In thread pool, processed data for fd " << sock_fd << std::endl;
            }

            // 数据处理完毕，通知 Reactor 修改事件为可写
            reactor->modify(sock_fd, WRITE);
            });
    }
}

void SockHandler::handle_write() {
    std::cout << "handle_write() called for fd " << sock_fd << std::endl;
    std::string to_send;

    // 从缓冲区取出待发送数据
    {
        std::lock_guard<std::mutex> lock(buf_mutex);
        if (write_buf.empty()) {
            return; // 没有数据需要发送
        }
        to_send.swap(write_buf); // 使用 swap 提高效率
    }

    size_t total_sent = 0;
    // 边缘触发(ET)模式下，必须循环写入，直到数据全部写完或缓冲区满
    while (total_sent < to_send.size()) {
        size_t n = send(sock_fd, to_send.c_str() + total_sent, to_send.size() - total_sent, 0);
        if (n > 0) {
            total_sent += n;
        }
        else { // n <= 0
            // 在非阻塞模式下，EAGAIN 或 EWOULDBLOCK 表示内核发送缓冲区已满
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::cout << "Kernel write buffer full for fd " << sock_fd << std::endl;
                break; // 退出循环，等待下一次可写通知
            }
            else {
                perror("send error");
                handle_error();
                return;
            }
        }
    }

    // 检查是否所有数据都已发送
    if (total_sent < to_send.size()) {
        // 如果数据没有发送完（因为缓冲区满了），把剩下的数据放回写缓冲区
        std::lock_guard<std::mutex> lock(buf_mutex);
        write_buf.insert(0, to_send.substr(total_sent));
    }
    else {
        std::cout << "All data sent for fd " << sock_fd << ". Total " << total_sent << " bytes." << std::endl;
        // 所有数据都已发送完毕，切回监听读事件
        reactor->modify(sock_fd, READ);
    }
}

void SockHandler::handle_error() {
    reactor->remove(sock_fd);
}

void SockHandler::handle_close() {
    // 这个函数在 reactor->remove() 中被调用，可以留空或添加一些清理逻辑
}