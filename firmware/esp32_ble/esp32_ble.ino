// MEDILINK ESP32 BLE firmware — Step 1: connectivity only.
// No sensor data, no dataset replay. Just advertise, accept a connection,
// expose the Nordic UART Service, and log connect/disconnect to Serial.

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>

#define DEVICE_NAME     "MEDILINK-ESP32"
#define SERVICE_UUID    "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
#define NOTIFY_CHAR_UUID "6e400003-b5a3-f393-e0a9-e50e24dcca9e"

BLECharacteristic *notifyChar;

class ConnectionCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer *server) override {
    Serial.println("BLE client connected");
  }

  void onDisconnect(BLEServer *server) override {
    Serial.println("BLE client disconnected");
    server->getAdvertising()->start(); // resume advertising for next client
    Serial.println("Advertising restarted");
  }
};

void setup() {
  Serial.begin(115200);
  Serial.println("Starting MEDILINK ESP32 BLE firmware...");

  BLEDevice::init(DEVICE_NAME);

  BLEServer *server = BLEDevice::createServer();
  server->setCallbacks(new ConnectionCallbacks());

  BLEService *service = server->createService(SERVICE_UUID);

  notifyChar = service->createCharacteristic(
      NOTIFY_CHAR_UUID,
      BLECharacteristic::PROPERTY_NOTIFY
  );
  notifyChar->addDescriptor(new BLE2902());

  service->start();

  BLEAdvertising *advertising = BLEDevice::getAdvertising();
  advertising->addServiceUUID(SERVICE_UUID);
  advertising->setScanResponse(true);
  BLEDevice::startAdvertising();

  Serial.println("Advertising as MEDILINK-ESP32");
  Serial.println("Nordic UART service ready, waiting for connections...");
}

void loop() {
  // Nothing yet — connectivity only, per Step 1.
}
