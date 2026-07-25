// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'engine_messages.dart';

// **************************************************************************
// JsonSerializableGenerator
// **************************************************************************

RequestEngineVersion _$RequestEngineVersionFromJson(
  Map<String, dynamic> json,
) =>
    RequestEngineVersion()
      ..expectedVersion = (json['expected_version'] as num).toInt();

Map<String, dynamic> _$RequestEngineVersionToJson(
  RequestEngineVersion instance,
) => <String, dynamic>{'expected_version': instance.expectedVersion};

Stop _$StopFromJson(Map<String, dynamic> json) => Stop();

Map<String, dynamic> _$StopToJson(Stop instance) => <String, dynamic>{};

IntifaceMessage _$IntifaceMessageFromJson(Map<String, dynamic> json) =>
    IntifaceMessage()
      ..requestEngineVersion = json['RequestEngineVersion'] == null
          ? null
          : RequestEngineVersion.fromJson(
              json['RequestEngineVersion'] as Map<String, dynamic>,
            )
      ..stop = json['Stop'] == null
          ? null
          : Stop.fromJson(json['Stop'] as Map<String, dynamic>);

Map<String, dynamic> _$IntifaceMessageToJson(IntifaceMessage instance) =>
    <String, dynamic>{
      'RequestEngineVersion': ?instance.requestEngineVersion?.toJson(),
      'Stop': ?instance.stop?.toJson(),
    };

EngineVersion _$EngineVersionFromJson(Map<String, dynamic> json) =>
    EngineVersion()..version = json['version'] as String;

EngineLogMessageSpan _$EngineLogMessageSpanFromJson(
  Map<String, dynamic> json,
) => EngineLogMessageSpan()..name = json['name'] as String?;

EngineLogMessageFields _$EngineLogMessageFieldsFromJson(
  Map<String, dynamic> json,
) => EngineLogMessageFields()
  ..message = json['message'] as String
  ..target = json['target'] as String
  ..span = json['span'] == null
      ? null
      : EngineLogMessageSpan.fromJson(json['span'] as Map<String, dynamic>)
  ..spans = (json['spans'] as List<dynamic>?)
      ?.map((e) => EngineLogMessageSpan.fromJson(e as Map<String, dynamic>))
      .toList();

EngineLogMessage _$EngineLogMessageFromJson(Map<String, dynamic> json) =>
    EngineLogMessage()
      ..timestamp = json['timestamp'] as String
      ..level = json['level'] as String
      ..fields = json['fields'] as Map<String, dynamic>
      ..target = json['target'] as String;

EngineLog _$EngineLogFromJson(Map<String, dynamic> json) =>
    $checkedCreate('EngineLog', json, ($checkedConvert) {
      $checkKeys(json, allowedKeys: const ['message']);
      final val = EngineLog();
      $checkedConvert('message', (v) => val.rawMessage = v as String?);
      return val;
    }, fieldKeyMap: const {'rawMessage': 'message'});

EngineStarted _$EngineStartedFromJson(Map<String, dynamic> json) =>
    EngineStarted();

EngineServerCreated _$EngineServerCreatedFromJson(Map<String, dynamic> json) =>
    EngineServerCreated()
      ..serviceType = json['service_type'] as String?
      ..instanceName = json['instance_name'] as String?
      ..port = (json['port'] as num?)?.toInt()
      ..txtRecords = (json['txt_records'] as List<dynamic>?)
          ?.map((e) => e as String)
          .toList();

EngineErrorDetail _$EngineErrorDetailFromJson(Map<String, dynamic> json) =>
    EngineErrorDetail()
      ..code = json['code'] as String
      ..port = (json['port'] as num?)?.toInt()
      ..address = json['address'] as String?;

EngineError _$EngineErrorFromJson(Map<String, dynamic> json) => EngineError()
  ..error = json['error'] as String
  ..detail = json['detail'] == null
      ? null
      : EngineErrorDetail.fromJson(json['detail'] as Map<String, dynamic>);

EngineStopped _$EngineStoppedFromJson(Map<String, dynamic> json) =>
    EngineStopped();

ClientConnected _$ClientConnectedFromJson(Map<String, dynamic> json) =>
    ClientConnected()..clientName = json['client_name'] as String;

ClientDisconnected _$ClientDisconnectedFromJson(Map<String, dynamic> json) =>
    ClientDisconnected();

SerializableUserConfigDeviceIdentifier
_$SerializableUserConfigDeviceIdentifierFromJson(Map<String, dynamic> json) =>
    SerializableUserConfigDeviceIdentifier(
      json['address'] as String,
      json['protocol'] as String,
      json['identifier'] as String?,
    );

Map<String, dynamic> _$SerializableUserConfigDeviceIdentifierToJson(
  SerializableUserConfigDeviceIdentifier instance,
) => <String, dynamic>{
  'address': instance.address,
  'protocol': instance.protocol,
  'identifier': ?instance.identifier,
};

DeviceConnected _$DeviceConnectedFromJson(Map<String, dynamic> json) =>
    DeviceConnected(
      name: json['name'] as String,
      index: (json['index'] as num).toInt(),
      identifier: SerializableUserConfigDeviceIdentifier.fromJson(
        json['identifier'] as Map<String, dynamic>,
      ),
      displayName: json['display_name'] as String?,
      needsKeepalive: json['needs_keepalive'] as bool? ?? false,
    );

DeviceDisconnected _$DeviceDisconnectedFromJson(Map<String, dynamic> json) =>
    DeviceDisconnected()..index = (json['index'] as num).toInt();

ClientRejected _$ClientRejectedFromJson(Map<String, dynamic> json) =>
    ClientRejected()..reason = json['reason'] as String;

EngineProviderLog _$EngineProviderLogFromJson(Map<String, dynamic> json) =>
    EngineProviderLog()
      ..timestamp = json['timestamp'] as String
      ..level = json['level'] as String
      ..message = json['message'] as String;

Map<String, dynamic> _$EngineProviderLogToJson(EngineProviderLog instance) =>
    <String, dynamic>{
      'timestamp': instance.timestamp,
      'level': instance.level,
      'message': instance.message,
    };

DeviceOutputObservation _$DeviceOutputObservationFromJson(
  Map<String, dynamic> json,
) => DeviceOutputObservation()
  ..deviceIndex = (json['device_index'] as num).toInt()
  ..featureIndex = (json['feature_index'] as num).toInt()
  ..outputType = json['output_type'] as String
  ..value = (json['value'] as num).toDouble();

Map<String, dynamic> _$DeviceOutputObservationToJson(
  DeviceOutputObservation instance,
) => <String, dynamic>{
  'device_index': instance.deviceIndex,
  'feature_index': instance.featureIndex,
  'output_type': instance.outputType,
  'value': instance.value,
};

EngineMessage _$EngineMessageFromJson(
  Map<String, dynamic> json,
) => EngineMessage()
  ..messageVersion = json['MessageVersion'] == null
      ? null
      : EngineVersion.fromJson(json['MessageVersion'] as Map<String, dynamic>)
  ..engineLog = json['EngineLog'] == null
      ? null
      : EngineLog.fromJson(json['EngineLog'] as Map<String, dynamic>)
  ..engineStarted = json['EngineStarted'] == null
      ? null
      : EngineStarted.fromJson(json['EngineStarted'] as Map<String, dynamic>)
  ..engineServerCreated = json['EngineServerCreated'] == null
      ? null
      : EngineServerCreated.fromJson(
          json['EngineServerCreated'] as Map<String, dynamic>,
        )
  ..engineError = json['EngineError'] == null
      ? null
      : EngineError.fromJson(json['EngineError'] as Map<String, dynamic>)
  ..engineStopped = json['EngineStopped'] == null
      ? null
      : EngineStopped.fromJson(json['EngineStopped'] as Map<String, dynamic>)
  ..clientConnected = json['ClientConnected'] == null
      ? null
      : ClientConnected.fromJson(
          json['ClientConnected'] as Map<String, dynamic>,
        )
  ..clientDisconnected = json['ClientDisconnected'] == null
      ? null
      : ClientDisconnected.fromJson(
          json['ClientDisconnected'] as Map<String, dynamic>,
        )
  ..deviceConnected = json['DeviceConnected'] == null
      ? null
      : DeviceConnected.fromJson(
          json['DeviceConnected'] as Map<String, dynamic>,
        )
  ..deviceDisconnected = json['DeviceDisconnected'] == null
      ? null
      : DeviceDisconnected.fromJson(
          json['DeviceDisconnected'] as Map<String, dynamic>,
        )
  ..clientRejected = json['ClientRejected'] == null
      ? null
      : ClientRejected.fromJson(json['ClientRejected'] as Map<String, dynamic>)
  ..engineProviderLog = json['EngineProviderLog'] == null
      ? null
      : EngineProviderLog.fromJson(
          json['EngineProviderLog'] as Map<String, dynamic>,
        )
  ..deviceOutputObservation = json['DeviceOutputObservation'] == null
      ? null
      : DeviceOutputObservation.fromJson(
          json['DeviceOutputObservation'] as Map<String, dynamic>,
        );
