#pragma once

#include <QObject>
#include <QTcpSocket>
#include <QJsonObject>
#include <QJsonDocument>
#include <QJsonArray>
#include <QAbstractSocket>
class NetworkManager : public QObject
{
    Q_OBJECT
public:
    explicit NetworkManager(QObject *parent = nullptr);
    void connect_to_server(const QString& ip, quint16 port);
    void send_login_request(const QString& username);
    void send_chat_message(const QString& text);
    void disconnect_from_server();

signals:
    void connected();
    void disconnected();
    void chat_message_received(const QString& username, const QString& text);
    void user_list_updated(const QStringList& users);
    void system_notification_received(const QString& message);
    void connection_error(const QString& error_message);

private slots:
    void on_socket_state_changed(QAbstractSocket::SocketState socketState);
    void on_ready_read();
    void on_socket_error(QAbstractSocket::SocketError socketError);

private:
    void send_json(const QJsonObject& json);

    QTcpSocket* socket_;
    QByteArray buffer_; // 用于处理粘包问题
};
