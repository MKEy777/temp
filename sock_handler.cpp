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
    char read_buf[1024]; // �ֲ�����

    // ��Ե����(ET)ģʽ�£�����ѭ����ȡ��ֱ�����������ݱ�����
    while (true) {
        size_t n = recv(sock_fd, read_buf, sizeof(read_buf), 0);

        if (n > 0) {
            // ����ȡ��������׷�ӵ� received_data
            received_data.append(read_buf, n);
        }
        else if (n == 0) {
            // �ͻ��������ر�����
            std::cout << "Client closed connection on fd " << sock_fd << std::endl;
            handle_error();
            return; // ��������
        }
        else { // n < 0
            // �ڷ�����ģʽ�£�EAGAIN �� EWOULDBLOCK ��ʾ������ȫ����ȡ���
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::cout << "All data read for fd " << sock_fd << ". Total " << received_data.length() << " bytes." << std::endl;
                break; // �˳�ѭ��
            }
            else {
                // �������󣬵��ô�����
                perror("recv error");
                handle_error();
                return; // ��������
            }
        }
    }

    // ֻ����ȷʵ�յ�������ʱ����Ͷ�������̳߳�
    if (!received_data.empty()) {
        thread_pool->enqueue([this, data = std::move(received_data)]() {
            // ģ��ҵ����
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            std::string processed = data + " [processed by epoll]";

            {
                std::lock_guard<std::mutex> lock(buf_mutex);
                write_buf += processed;
                std::cout << "In thread pool, processed data for fd " << sock_fd << std::endl;
            }

            // ���ݴ�����ϣ�֪ͨ Reactor �޸��¼�Ϊ��д
            reactor->modify(sock_fd, WRITE);
            });
    }
}

void SockHandler::handle_write() {
    std::cout << "handle_write() called for fd " << sock_fd << std::endl;
    std::string to_send;

    // �ӻ�����ȡ������������
    {
        std::lock_guard<std::mutex> lock(buf_mutex);
        if (write_buf.empty()) {
            return; // û��������Ҫ����
        }
        to_send.swap(write_buf); // ʹ�� swap ���Ч��
    }

    size_t total_sent = 0;
    // ��Ե����(ET)ģʽ�£�����ѭ��д�룬ֱ������ȫ��д��򻺳�����
    while (total_sent < to_send.size()) {
        size_t n = send(sock_fd, to_send.c_str() + total_sent, to_send.size() - total_sent, 0);
        if (n > 0) {
            total_sent += n;
        }
        else { // n <= 0
            // �ڷ�����ģʽ�£�EAGAIN �� EWOULDBLOCK ��ʾ�ں˷��ͻ���������
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                std::cout << "Kernel write buffer full for fd " << sock_fd << std::endl;
                break; // �˳�ѭ�����ȴ���һ�ο�д֪ͨ
            }
            else {
                perror("send error");
                handle_error();
                return;
            }
        }
    }

    // ����Ƿ��������ݶ��ѷ���
    if (total_sent < to_send.size()) {
        // �������û�з����꣨��Ϊ���������ˣ�����ʣ�µ����ݷŻ�д������
        std::lock_guard<std::mutex> lock(buf_mutex);
        write_buf.insert(0, to_send.substr(total_sent));
    }
    else {
        std::cout << "All data sent for fd " << sock_fd << ". Total " << total_sent << " bytes." << std::endl;
        // �������ݶ��ѷ�����ϣ��лؼ������¼�
        reactor->modify(sock_fd, READ);
    }
}

void SockHandler::handle_error() {
    reactor->remove(sock_fd);
}

void SockHandler::handle_close() {
    // ��������� reactor->remove() �б����ã��������ջ����һЩ�����߼�
}