// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library jwt_token_generator;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:http/http.dart' as http;
import '../../auth.dart';
import '../crypto/rsa.dart';
import '../crypto/rsa_sign.dart';
import '../utils.dart';
import '../http_client_base.dart';

class JwtFlow {
  // All details are described at:
  // https://developers.google.com/accounts/docs/OAuth2ServiceAccount
  // JSON Web Signature (JWS) requires signing a string with a private key.

  static const GOOGLE_OAUTH2_TOKEN_URL =
      'https://accounts.google.com/o/oauth2/token';

  final String _clientEmail;
  final RS256Signer _signer;
  final List<String> _scopes;
  final http.Client _client;
  final String _userEmail;

  JwtFlow(this._clientEmail, RSAPrivateKey key, this._scopes, this._client, {String userEmail})
      : _signer = new RS256Signer(key), _userEmail = userEmail;

  Future<AccessCredentials> run() {
    int timestamp = new DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000
        - MAX_EXPECTED_TIMEDIFF_IN_SECONDS;

    jwtHeader() => {"alg": "RS256", "typ": "JWT"};

    jwtClaimSet() {
      return {
          'iss' : _clientEmail,
          'scope' : _scopes.join(' '),
          'aud' : GOOGLE_OAUTH2_TOKEN_URL,
          'exp' : timestamp + 3600,
          'iat' : timestamp,
          'sub': _userEmail
      };
    }

    var jwtHeaderBase64 = _base64url(ASCII.encode(JSON.encode(jwtHeader())));
    var jwtClaimSetBase64 = _base64url(UTF8.encode(JSON.encode(jwtClaimSet())));
    var jwtSignatureInput = '$jwtHeaderBase64.$jwtClaimSetBase64';
    var jwtSignatureInputInBytes = ASCII.encode(jwtSignatureInput);

    var signature = _signer.sign(jwtSignatureInputInBytes);
    var jwt = "$jwtSignatureInput.${_base64url(signature)}";

    var uri = 'urn:ietf:params:oauth:grant-type:jwt-bearer';
    var requestParameters = 'grant_type=${Uri.encodeComponent(uri)}&'
                            'assertion=${Uri.encodeComponent(jwt)}';

    var body = new Stream.fromIterable([UTF8.encode(requestParameters)]);
    var request = new RequestImpl(
        'POST', Uri.parse(GOOGLE_OAUTH2_TOKEN_URL), body);
    request.headers['content-type'] = CONTENT_TYPE_URLENCODED;

    return _client.send(request).then((http.StreamedResponse httpResponse) {
      return httpResponse.stream
          .transform(UTF8.decoder)
          .transform(JSON.decoder)
          .first.then((Map response) {
        var tokenType = response['token_type'];
        var token = response['access_token'];
        var expiresIn = response['expires_in'];
        var error = response['error'];

        if (httpResponse.statusCode != 200 && error != null) {
          throw new Exception('Unable to obtain credentials. Error: $error.');
        }

        if (tokenType != 'Bearer' || token == null || expiresIn is! int) {
          throw new Exception(
              'Unable to obtain credentials. Invalid response from server.');
        }
        var accessToken = new AccessToken(
            tokenType, token, expiryDate(expiresIn));
        return new AccessCredentials(accessToken, null, _scopes);
      });
    });
  }

  String _base64url(List<int> bytes) {
    return CryptoUtils.bytesToBase64(bytes)
      .replaceAll('+', '-').replaceAll('/', '_').replaceAll('=', '');
  }
}
