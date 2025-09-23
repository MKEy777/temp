#include <iostream>
#include <string>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cstring>
#include <cerrno>

// 客户端逻辑
int run_client() {
    int sock = socket(AF_INET, SOCK_STREAM, 0);
    if (sock < 0) {
        std::cerr << "Socket creation failed" << std::endl;
        return 1;
    }

    sockaddr_in serv_addr;
    serv_addr.sin_family = AF_INET;
    serv_addr.sin_port = htons(8080); // 确保端口号与服务端一致

    if (inet_pton(AF_INET, "127.0.0.1", &serv_addr.sin_addr) <= 0) {
        std::cerr << "Invalid address" << std::endl;
        close(sock);
        return 1;
    }

    if (connect(sock, (struct sockaddr*)&serv_addr, sizeof(serv_addr)) < 0) {
        std::cerr << "Connection Failed: " << strerror(errno) << std::endl;
        close(sock);
        return 1;
    }

    std::cout << "Connected to server. Type 'exit' to quit." << std::endl;

    while (true) {
        std::string message;
        std::cout << "> ";
        std::getline(std::cin, message);

        if (message == "exit" || std::cin.eof()) break;

        send(sock, message.c_str(), message.length(), 0);

        char buffer[1024] = { 0 };
        int valread = recv(sock, buffer, 1024, 0);
        if (valread > 0) {
            std::cout << "Server response: " << std::string(buffer, valread) << std::endl;
        }
        else {
            std::cout << "Server closed connection." << std::endl;
            break;
        }
    }

    close(sock);
    return 0;
}