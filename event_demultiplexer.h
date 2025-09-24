#pragma once
#include <map>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <fcntl.h>

typedef int Handle;//socket ������
const int INVALID_SOCKET = -1;
const int SOCKET_ERROR = -1;

enum Event { READ = 0x1, WRITE = 0x2, ERROR = 0x4 };

class EventHandler;

class EventDemultiplexer {
public:
    virtual ~EventDemultiplexer() {}
    //�ȴ��¼�����
    virtual int wait_event(std::map<Handle, EventHandler*>& handlers, int timeout = 0) = 0;
	//ע��socket���¼�
    virtual bool regist(Handle handle, Event evt) = 0;
    //�Ƴ�socket
    virtual bool remove(Handle handle) = 0;
};