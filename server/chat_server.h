#pragma once
#include "event_demultiplexer.h" // For Handle type
#include "reactor.h"              // For Reactor forward declaration
#include <map>
#include <mutex>
#include <string>
#include <vector>

class ClientHandler; // ǰ������
class Reactor;       // ǰ������

class ChatServer {
public:
    // ���캯������ Sub-Reactor ��ָ�룬���������ɷ�
    explicit ChatServer(Reactor* sub_reactor);
    ~ChatServer();

    void on_client_connected(ClientHandler* client);
    void on_client_disconnected(Handle fd);

    // �����޸ģ����վ������ָ�룬�ڹ����߳��б�����
    void process_message(Handle client_handle, const std::string& json_data);

private:
    // �������������������� Sub-Reactor �߳��б���ȫ����
    void broadcast_message(const std::string& json_message, Handle except_fd = -1);
    void broadcast_user_list();

    // ��Ա����
    Reactor* sub_reactor_; // ���� Sub-Reactor ��ָ��
    std::map<Handle, ClientHandler*> clients_;
    std::mutex clients_mutex_;
};