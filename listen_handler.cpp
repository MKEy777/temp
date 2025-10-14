#include "listen_handler.h"
#include "client_handler.h" 
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>
#include <iostream>
#include <string.h> 

// ���캯���޸ģ��Խ��� ChatServer ָ��
ListenHandler::ListenHandler(int port, Reactor* sub_reactors, ChatServer* server)
    : sub_reactors_(sub_reactors), chat_server_(server)
{
    listen_fd_ = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd_ < 0) {
        std::cerr << "socket create failed: " << strerror(errno) << std::endl;
        return;
    }

    // ���� SO_REUSEADDR ѡ������������������
    int opt = 1;
    if (setsockopt(listen_fd_, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        std::cerr << "setsockopt(SO_REUSEADDR) failed: " << strerror(errno) << std::endl;
    }

    sockaddr_in addr;
    bzero(&addr, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((short)port);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(listen_fd_, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        std::cerr << "bind failed: " << strerror(errno) << std::endl;
        close(listen_fd_);
        return;
    }

    if (listen(listen_fd_, 1024) < 0) {
        std::cerr << "listen failed: " << strerror(errno) << std::endl;
        close(listen_fd_);
        return;
    }

    set_non_blocking(listen_fd_);
    std::cout << "Server listening on port " << port << std::endl;
}

ListenHandler::~ListenHandler() {
    if (listen_fd_ >= 0) {
        close(listen_fd_);
    }
}

Handle ListenHandler::get_handle() const {
    return listen_fd_;
}

// ���������ӵ���ʱ������ ClientHandler
void ListenHandler::handle_read() {
    sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);
    Handle client_fd = accept(listen_fd_, (struct sockaddr*)&client_addr, &addr_len);
    if (client_fd > 0) {
        set_non_blocking(client_fd);
        std::cout << "Accepted new connection with fd " << client_fd << std::endl;

        // �����µ� ClientHandler������ sub-reactor �� chat_server ʵ�����ݽ�ȥ
        EventHandler* client_handler = new ClientHandler(client_fd, sub_reactors_, chat_server_);
        sub_reactors_->regist(client_handler, READ);
    }
    else {
        // ��� accept ʧ�ܣ���ӡ������Ϣ
        std::cerr << "accept failed: " << strerror(errno) << std::endl;
    }
}

// �����������Ҫд����
void ListenHandler::handle_write() {
    //
}

void ListenHandler::handle_error() {
    std::cerr << "ListenHandler error, closing listen socket." << std::endl;
    close(listen_fd_);
}

void ListenHandler::set_non_blocking(Handle fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0) {
        perror("fcntl F_GETFL");
        return;
    }
    if (fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) {
        perror("fcntl F_SETFL");
    }
}
void ListenHandler::handle_close() {
    close(listen_fd_);
    delete this;
}