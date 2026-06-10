// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'matrix.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SyncEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent()';
}


}

/// @nodoc
class $SyncEventCopyWith<$Res>  {
$SyncEventCopyWith(SyncEvent _, $Res Function(SyncEvent) __);
}


/// Adds pattern-matching-related methods to [SyncEvent].
extension SyncEventPatterns on SyncEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SyncEvent_SyncCompleted value)?  syncCompleted,TResult Function( SyncEvent_MessageSent value)?  messageSent,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SyncEvent_SyncCompleted value)  syncCompleted,required TResult Function( SyncEvent_MessageSent value)  messageSent,}){
final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted():
return syncCompleted(_that);case SyncEvent_MessageSent():
return messageSent(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SyncEvent_SyncCompleted value)?  syncCompleted,TResult? Function( SyncEvent_MessageSent value)?  messageSent,}){
final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted(_that);case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function()?  syncCompleted,TResult Function( String roomId)?  messageSent,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted();case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that.roomId);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function()  syncCompleted,required TResult Function( String roomId)  messageSent,}) {final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted():
return syncCompleted();case SyncEvent_MessageSent():
return messageSent(_that.roomId);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function()?  syncCompleted,TResult? Function( String roomId)?  messageSent,}) {final _that = this;
switch (_that) {
case SyncEvent_SyncCompleted() when syncCompleted != null:
return syncCompleted();case SyncEvent_MessageSent() when messageSent != null:
return messageSent(_that.roomId);case _:
  return null;

}
}

}

/// @nodoc


class SyncEvent_SyncCompleted extends SyncEvent {
  const SyncEvent_SyncCompleted(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_SyncCompleted);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent.syncCompleted()';
}


}




/// @nodoc


class SyncEvent_MessageSent extends SyncEvent {
  const SyncEvent_MessageSent({required this.roomId}): super._();
  

 final  String roomId;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_MessageSentCopyWith<SyncEvent_MessageSent> get copyWith => _$SyncEvent_MessageSentCopyWithImpl<SyncEvent_MessageSent>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_MessageSent&&(identical(other.roomId, roomId) || other.roomId == roomId));
}


@override
int get hashCode => Object.hash(runtimeType,roomId);

@override
String toString() {
  return 'SyncEvent.messageSent(roomId: $roomId)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_MessageSentCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_MessageSentCopyWith(SyncEvent_MessageSent value, $Res Function(SyncEvent_MessageSent) _then) = _$SyncEvent_MessageSentCopyWithImpl;
@useResult
$Res call({
 String roomId
});




}
/// @nodoc
class _$SyncEvent_MessageSentCopyWithImpl<$Res>
    implements $SyncEvent_MessageSentCopyWith<$Res> {
  _$SyncEvent_MessageSentCopyWithImpl(this._self, this._then);

  final SyncEvent_MessageSent _self;
  final $Res Function(SyncEvent_MessageSent) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? roomId = null,}) {
  return _then(SyncEvent_MessageSent(
roomId: null == roomId ? _self.roomId : roomId // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
