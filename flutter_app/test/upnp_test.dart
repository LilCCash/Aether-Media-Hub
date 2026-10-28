import 'package:aether_flutter/core/casting/upnp.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fake_adapter.dart';

const _description = '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
 <URLBase>http://192.168.1.50:8000/</URLBase>
 <device>
  <friendlyName>Salotto</friendlyName>
  <manufacturer>Acme</manufacturer>
  <modelName>TV 5000</modelName>
  <UDN>uuid:abc</UDN>
  <serviceList>
   <service>
    <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
    <controlURL>/upnp/control/AVTransport</controlURL>
   </service>
   <service>
    <serviceType>urn:schemas-upnp-org:service:RenderingControl:1</serviceType>
    <controlURL>/upnp/control/RenderingControl</controlURL>
   </service>
   <service>
    <serviceType>urn:schemas-upnp-org:service:Evil:1</serviceType>
    <controlURL>http://203.0.113.9/attack</controlURL>
   </service>
  </serviceList>
 </device>
</root>''';

String _soapOk(Map<String, String> values) =>
    '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:Resp xmlns:u="x">'
    '${values.entries.map((e) => '<${e.key}>${e.value}</${e.key}>').join()}'
    '</u:Resp></s:Body></s:Envelope>';

void main() {
  final location = Uri.parse('http://192.168.1.50:8000/desc.xml');

  test('the description gives the name, the services, and drops control addresses on another host', () {
    final d = UpnpDescriptionParser.parse(_description, location);
    expect(d.friendlyName, 'Salotto');
    expect(d.udn, 'uuid:abc');
    expect(d.isMediaRenderer, isTrue);
    expect(
      d.avTransport!.controlUrl.toString(),
      'http://192.168.1.50:8000/upnp/control/AVTransport',
    );
    expect(d.services.length, 2); // the one pointing to 203.0.113.9 is refused
    expect(
      () => UpnpDescriptionParser.parse('<nope', location),
      throwsA(isA<UpnpException>()),
    );
  });

  test('only local addresses are accepted', () {
    for (final ok in [
      '10.0.0.2',
      '192.168.1.5',
      '172.16.9.1',
      '172.31.0.1',
      '169.254.3.3',
    ]) {
      expect(isLocalHost(ok), isTrue, reason: ok);
    }
    for (final no in [
      '8.8.8.8',
      '172.32.0.1',
      '203.0.113.9',
      'example.com',
      '127.0.0.1',
      '300.1.1.1',
      '',
    ]) {
      expect(isLocalHost(no), isFalse, reason: no);
    }
  });

  test(
    'SSDP: the search text, and answers are used only with a LAN http location',
    () {
      final req = String.fromCharCodes(Ssdp.searchRequest());
      expect(req, startsWith('M-SEARCH * HTTP/1.1'));
      expect(req, contains('ST: urn:schemas-upnp-org:device:MediaRenderer:1'));
      expect(
        Ssdp.parseLocation(
          'HTTP/1.1 200 OK\r\nLOCATION: http://192.168.1.50:8000/desc.xml\r\nST: x\r\n\r\n',
        ),
        Uri.parse('http://192.168.1.50:8000/desc.xml'),
      );
      expect(
        Ssdp.parseLocation(
          'HTTP/1.1 200 OK\r\nLOCATION: http://203.0.113.9/d.xml\r\n\r\n',
        ),
        isNull,
      );
      expect(
        Ssdp.parseLocation(
          'HTTP/1.1 200 OK\r\nLOCATION: file:///etc/passwd\r\n\r\n',
        ),
        isNull,
      );
      expect(
        Ssdp.parseLocation(
          'HTTP/1.1 404 Not Found\r\nLOCATION: http://192.168.1.5/\r\n\r\n',
        ),
        isNull,
      );
    },
  );

  test('SOAP and DIDL-Lite escape what they carry; times round trip', () {
    expect(Soap.escape('a&b<c>"d\''), 'a&amp;b&lt;c&gt;&quot;d&apos;');
    final env = Soap.envelope('urn:x:service:AVTransport:1', 'Play', [
      ('InstanceID', '0'),
      ('Speed', '1'),
    ]);
    expect(env, contains('<u:Play xmlns:u="urn:x:service:AVTransport:1">'));
    expect(env, contains('<Speed>1</Speed>'));
    expect(
      Soap.headers('urn:x:service:AVTransport:1', 'Play')['SOAPAction'],
      '"urn:x:service:AVTransport:1#Play"',
    );
    final didl = Didl.metadata(
      title: 'A & B <1>',
      url: Uri.parse('https://x/a.mkv?x=1&y=2'),
      mime: 'video/x-matroska',
    );
    expect(didl, contains('A &amp; B &lt;1&gt;'));
    expect(didl, contains('x=1&amp;y=2'));
    expect(Didl.mimeType('MKV'), 'video/x-matroska');
    expect(Didl.formatTime(3725.5), '1:02:05');
    expect(Didl.parseTime('01:02:05.500'), closeTo(3725.5, 0.001));
    expect(Didl.parseTime('NOT_IMPLEMENTED'), isNull);
    final fault = Soap.parseResponse(
      '<e><UPnPError><errorCode>701</errorCode><errorDescription>Transition not available</errorDescription></UPnPError></e>',
    );
    expect(fault.fault, contains('701'));
  });

  test('casting: SetAVTransportURI with metadata, then Play; the volume and the state are read back', () async {
    final calls = <String>[];
    final bodies = <String>[];
    final client = UpnpClient(
      dio: fakeDio((o) {
        if (o.method == 'GET') return (status: 200, body: _description);
        final action = (o.headers['SOAPAction'] as String)
            .split('#')
            .last
            .replaceAll('"', '');
        calls.add(action);
        bodies.add('${o.data}');
        if (action == 'GetTransportInfo') {
          return (
            status: 200,
            body: _soapOk({'CurrentTransportState': 'PLAYING'}),
          );
        }
        return (status: 200, body: _soapOk({}));
      }),
    );
    final d = await client.fetchDevice(location);
    await client.cast(d, Uri.parse('https://cdn.example/film.mkv'), 'Film');
    expect(calls, ['SetAVTransportURI', 'Play']);
    expect(
      bodies.first,
      contains('<CurrentURI>https://cdn.example/film.mkv</CurrentURI>'),
    );
    expect(bodies.first, contains('video/x-matroska'));
    expect(await client.state(d), UpnpTransportState.playing);
    await client.setVolume(d, 140);
    expect(bodies.last, contains('<DesiredVolume>100</DesiredVolume>'));
    await expectLater(
      client.cast(d, Uri.parse('file:///tmp/a.mp4'), 'x'),
      throwsA(isA<UpnpException>()),
    );
    await expectLater(
      client.fetchDevice(Uri.parse('http://203.0.113.9/d.xml')),
      throwsA(isA<UpnpException>()),
    );
  });

  test(
    'a television that refuses a command is reported without echoing the link',
    () async {
      final client = UpnpClient(
        dio: fakeDio((o) {
          if (o.method == 'GET') return (status: 200, body: _description);
          return (
            status: 500,
            body: '<e><UPnPError><errorCode>714</errorCode><errorDescription>Illegal MIME-type</errorDescription></UPnPError></e>',
          );
        }),
      );
      final d = await client.fetchDevice(location);
      try {
        await client.cast(
          d,
          Uri.parse('https://cdn.example/secret-token-123/film.mkv'),
          'Film',
        );
        fail('expected a failure');
      } on UpnpException catch (e) {
        expect(e.message, contains('714'));
        expect(e.message, isNot(contains('secret-token-123')));
      }
    },
  );
}
