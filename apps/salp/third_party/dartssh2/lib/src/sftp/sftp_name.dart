import 'dart:convert';
import 'dart:typed_data';
import 'package:dartssh2/src/sftp/sftp_file_attrs.dart';
import 'package:dartssh2/src/ssh_message.dart';

class SftpName {
  final Uint8List filenameBytes;
  final Uint8List longnameBytes;
  final SftpFileAttrs attr;
  String get filename => utf8.decode(filenameBytes,allowMalformed:true);
  String get longname => utf8.decode(longnameBytes,allowMalformed:true);
  SftpName({required String filename,required String longname,required this.attr})
    : filenameBytes=Uint8List.fromList(utf8.encode(filename)),longnameBytes=Uint8List.fromList(utf8.encode(longname));
  SftpName.bytes({required this.filenameBytes,required this.longnameBytes,required this.attr});
  factory SftpName.readFrom(SSHMessageReader reader) => SftpName.bytes(
    filenameBytes:Uint8List.fromList(reader.readString()),
    longnameBytes:Uint8List.fromList(reader.readString()),attr:SftpFileAttrs.readFrom(reader));
  void writeTo(SSHMessageWriter writer) {
    writer.writeString(filenameBytes); writer.writeString(longnameBytes); attr.writeTo(writer);
  }
  @override
  String toString()=>'SftpName(attributes: $attr)';
}
