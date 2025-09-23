#include "listen_handler.h"
#include <iostream>
#include <cerrno> 
#include <cstdio>


ListenHandler::ListenHandler(int port, Reactor* sub) : sub_reactor(sub) {
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd == INVALID_SOCKET) {
        perror("socket creation failed");
        return;
    }

    int opt = 1;
    setsockopt(listen_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_ANY);
    addr.sin_port = htons(port);
    if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) == SOCKET_ERROR) {
        perror("bind failed");
        close(listen_fd);
        listen_fd = INVALID_SOCKET;
        return;
    }

    if (listen(listen_fd, 1024) == SOCKET_ERROR) {
        perror("listen failed");
        close(listen_fd);
        listen_fd = INVALID_SOCKET;
        return;
    }
    std::cout << "Server listening on port " << port << std::endl;
}

ListenHandler::~ListenHandler() {
    if (listen_fd != INVALID_SOCKET) close(listen_fd);
}

Handle ListenHandler::get_handle() const { return listen_fd; }

void ListenHandler::set_non_blocking(Handle fd) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK);
}

void ListenHandler::handle_read() {
    sockaddr_in client_addr;
    socklen_t addr_len = sizeof(client_addr);
    Handle client_fd = accept(listen_fd, (struct sockaddr*)&client_addr, &addr_len);

    if (client_fd > 0) {
        set_non_blocking(client_fd);
        std::cout << "Accepted new connection with fd " << client_fd << std::endl;
        SockHandler* client_handler = new SockHandler(client_fd, sub_reactor);
        sub_reactor->regist(client_handler, READ);
    }
    else {
        perror("accept failed");
    }
}

void ListenHandler::handle_write() {}
void ListenHandler::handle_error() { close(listen_fd); }
void ListenHandler::handle_close() { if (listen_fd != INVALID_SOCKET) close(listen_fd); }