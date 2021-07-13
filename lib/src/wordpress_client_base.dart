import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:wordpress_client/src/enums.dart';
import 'package:wordpress_client/src/wordpress_authorization.dart';
import 'package:wordpress_client/wordpress_client.dart';
import 'exceptions/authorization_failed_exception.dart';
import 'exceptions/null_reference_exception.dart';
import 'requests/builders/request_builder.dart';
import 'requests/request.dart';
import 'responses/post_response.dart';
import 'responses/response_container.dart';
import 'utilities/cookie_container.dart';
import 'utilities/pair.dart';
import 'utilities/helpers.dart';

const int defaultRequestTimeout = 60;

class WordpressClient {
  Dio _client;
  CookieContainer _cookies;
  String _baseUrl;
  String _path;
  WordpressAuthorization _defaultAuthorization;
  bool Function(dynamic) _responsePreprocessorDelegate;

  WordpressClient(String baseUrl, String path, {CookieContainer cookieContainer}) {
    _client = Dio(
      BaseOptions(
        connectTimeout: defaultRequestTimeout,
        receiveTimeout: defaultRequestTimeout,
        followRedirects: true,
        maxRedirects: 5,
      ),
    );

    if (baseUrl == null) {
      throw NullReferenceException('Base URL is invalid.');
    }

    if (path == null) {
      throw NullReferenceException('Endpoint is invalid.');
    }

    _baseUrl = baseUrl;
    _path = path;
    _cookies = cookieContainer ?? CookieContainer();
  }

  WordpressClient withDefaultUserAgent(String userAgent) {
    _client.options.headers['User-Agent'] = userAgent;
    return this;
  }

  Future<WordpressClient> withDefaultAuthorization(WordpressAuthorization auth) async {
    if (auth == null || auth.isDefault) {
      return this;
    }

    if (_defaultAuthorization != null && !_defaultAuthorization.isDefault) {
      return this;
    }

    _defaultAuthorization = auth;
    var encryptedAccessToken = null;
    if (!_defaultAuthorization.isValidAuth &&
        _defaultAuthorization.authType == AuthorizationType.JWT &&
        !await _defaultAuthorization.handleJwtAuthentication(parseUrl(_baseUrl, _path), _client, (token) {
          encryptedAccessToken = token;
        })) {
      return this;
    }

    if (!isNullOrEmpty(encryptedAccessToken)) {
      _client.options.headers['Authorization'] = '${_defaultAuthorization.scheme} $encryptedAccessToken';
    }

    return this;
  }

  WordpressClient withGlobalResponsePreprocessorDelegate(bool Function(dynamic) delgate) {
    _responsePreprocessorDelegate = delgate;
    return this;
  }

  WordpressClient withCookieContainer(CookieContainer cookies) {
    _cookies = cookies;
    return this;
  }

  WordpressClient withDefaultRequestHeaders(List<Pair<String, String>> headers) {
    for (final header in headers) {
      _client.options.headers[header.a] = header.b;
    }

    return this;
  }

  Future<ResponseContainer<List<Post>>> fetchPosts(Request Function(RequestBuilder) builder) async {
    final response = await _postRequestAsync<dynamic>(
        builder(RequestBuilder().initializeWithDefaultValues().withBaseAndEndpoint(parseUrl(_baseUrl, _path), 'posts')));

    return ResponseContainer(
      List<Post>.from((response.value as Iterable<dynamic>).map<Post>((e) => Post.fromMap(e))),
      responseCode: response.responseCode,
      status: response.status,
      responseHeaders: response.responseHeaders,
      duration: response.duration,
      exception: response.exception,
      errorMessage: response.errorMessage,
    );
  }

  Future<ResponseContainer<T>> _postRequestAsync<T>(Request request) async {
    if (request == null || request.requestUri == null) {
      return null;
    }

    var watch = Stopwatch()..start();
    try {
      final response = await _client.fetch(await _parseAsDioRequest(request));
      watch.stop();

      if (response == null || response.statusCode != 200) {
        return ResponseContainer<T>.failed(
          null,
          duration: watch.elapsed,
          errorMessage: response.statusMessage,
          status: false,
          responseCode: response.statusCode,
        );
      }

      if (_responsePreprocessorDelegate != null && !_responsePreprocessorDelegate(response.data)) {
        return ResponseContainer<T>.failed(
          null,
          duration: watch.elapsed,
          errorMessage: 'Request aborted by user in responsePreprocessorDelegate()',
          status: false,
          responseCode: response.statusCode,
        );
      }

      if (request.callback?.responseCallback != null) {
        request.callback.responseCallback(response.data);
      }

      if (request.validationDelegate != null && !request.validationDelegate(jsonDecode(response.data))) {
        return ResponseContainer<T>.failed(
          null,
          duration: watch.elapsed,
          errorMessage: 'Request aborted by user in validationDelegate()',
          status: false,
          responseCode: response.statusCode,
        );
      }

      return ResponseContainer<T>(
        response.data,
        responseCode: response.statusCode,
        status: true,
        responseHeaders: _parseResponseHeaders(response.headers.map),
        duration: watch.elapsed,
      );
    } on Exception catch (e) {
      if (request.callback?.unhandledExceptionCallback != null) {
        request.callback.unhandledExceptionCallback(e);
      }

      return ResponseContainer<T>.failed(
        null,
        duration: watch.elapsed,
        errorMessage: 'Exception occured.',
        status: false,
        exception: e,
        responseCode: 400,
      );
    }
  }

  List<Pair<String, String>> _parseResponseHeaders(Map<String, List<String>> headers) {
    if (headers == null) {
      return [];
    }

    var headerPairs = <Pair<String, String>>[];
    for (final header in headers.entries) {
      headerPairs.add(Pair(header.key, header.value.join(';')));
    }

    return headerPairs;
  }

  Future<RequestOptions> _parseAsDioRequest(Request request) async {
    if (request == null) {
      throw NullReferenceException('Request object is null');
    }

    RequestOptions options = RequestOptions(
      path: request.requestUri.toString(),
      method: request.httpMethod.toString().split('.').last,
      cancelToken: request.cancelToken,
    );

    if (request.shouldAuthorize) {
      options = await WordpressAuthorization.authorizeRequest(options, _client, parseUrl(_baseUrl, _path), request.authorization);

      if (options == null) {
        throw AuthorizationFailedException();
      }
    }

    print('Request URL: ${options.path}');

    if (request.headers != null && request.headers.isNotEmpty) {
      for (final pair in request.headers) {
        options.headers[pair.a] = pair.b;
      }
    }

    if (request.formBody != null) {
      switch (request.formBody['REQUEST_TYPE']) {
        case 'media_request':
          options.headers.addEntries(request.formBody.entries.where((element) => element.key != 'file'));
          options.data = request.formBody['file'];
          break;
        case 'post_request':
          options.data = request.formBody;
          break;
      }
    }

    return options;
  }
}
