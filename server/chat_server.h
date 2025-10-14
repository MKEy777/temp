#pragma once
#include "event_demultiplexer.h" // For Handle type
#include "reactor.h"              // For Reactor forward declaration
#include <map>
#include <mutex>
#include <string>
#include <vector>

class ClientHandler; // 前向声明
class Reactor;       // 前向声明

class ChatServer {
public:
    // 构造函数接收 Sub-Reactor 的指针，用于任务派发
    explicit ChatServer(Reactor* sub_reactor);
    ~ChatServer();

    void on_client_connected(ClientHandler* client);
    void on_client_disconnected(Handle fd);

    // 参数修改：接收句柄而非指针，在工作线程中被调用
    void process_message(Handle client_handle, const std::string& json_data);

private:
    // 这两个方法现在总是在 Sub-Reactor 线程中被安全调用
    void broadcast_message(const std::string& json_message, Handle except_fd = -1);
    void broadcast_user_list();

    // 成员变量
    Reactor* sub_reactor_; // 保存 Sub-Reactor 的指针
    std::map<Handle, ClientHandler*> clients_;
    std::mutex clients_mutex_;
};