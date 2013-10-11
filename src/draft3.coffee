# TODO: clone the input schema

deap = require "deap"

URI = require "./uri"

escape = (string) ->
  string
    .replace(/~0/g, "~")
    .replace(/~1/g, "/")
    .replace(/%25/g, "%")

class Context

  constructor: ({@pointer, @scope}) ->

  child: (token) ->
    new Context
      pointer: "#{@pointer}/#{token}"
      scope: @scope

  #change_scope: (id) ->
    #@scope = URI.resolve(@scope, id)

module.exports = class Validator

  constructor: (schemas...) ->
    @references = {}
    @tests = {}
    @unresolved = {}

    for schema in schemas
      @add(schema)


  add: (schema) ->
    schema = deap.clone(schema)

    if schema.id
      # Make sure the schema id always ends with "#"
      schema.id = schema.id.replace /#?$/, "#"

    context = new Context
      pointer: schema.id || "#"
      scope: schema.id || "#"
    @compile_references schema, context

    # We try one more time to resolve $ref values, because
    # a schema may have been defined after we initially
    # tried to resolve the $ref.
    for ref, {scope, uri} of @unresolved
      if found_schema = @resolve_ref(uri, scope)
        delete @unresolved[ref]
        @references[ref] = found_schema
    if Object.keys(@unresolved).length > 0
      console.log "Unresolvable $ref values:", @unresolved

    @compile(schema, context)




  validate: (data) ->
    @validate_schema("#", data)

  validate_schema: (uri, data) ->
    if @tests[uri]
      valid: @tests[uri](data)
    else
      throw new Error "No schema found for '#{uri}'"

  find: (uri) ->
    uri = escape(uri)
    @references[uri]

  resolve_ref: (uri, scope) ->
    if schema = @find(uri)
      if schema.$ref
        uri = URI.resolve(scope, schema.$ref)
        @resolve_ref(uri)
      else
        return schema
    else
      null


  compile_references: (schema, context) ->
    {scope, pointer} = context
    @references[pointer] = schema
    # This is one of the two places we pay attention to "id".
    # Here, we treat non-JSON-pointer fragments (such as "#user") as aliases.
    if schema.id && schema.id.indexOf("#") == 0
      uri = URI.resolve scope, schema.id
      @references[uri] = schema

    if @test_type "object", schema
      for attribute, definition of schema
        new_context = context.child(attribute)
        switch attribute
          when "$ref"
            uri = URI.resolve(scope, definition)

            # ignore recursive references
            if pointer.indexOf(uri) != 0
              if schema = @resolve_ref(uri, scope)
                @compile_references schema, context
              else
                @unresolved[pointer] = {scope: context.scope, uri: uri}

          when "type"
            if @test_type "array", definition
              @type_refs definition, new_context
          when "properties", "patternProperties"
            @dictionary_refs definition, new_context
          when "items"
            @items_refs definition, new_context
          when "additionalItems", "additionalProperties", "extends"
            @compile_references definition, context.child(attribute)
          else
            if !@attributes[attribute] && @test_type "object", definition
              @compile_references definition, context.child(attribute)


  type_refs: (union, context) ->
    for schema, i in union
      if @test_type "object", schema
        @compile_references schema, context.child(i.toString())

  dictionary_refs: (properties, context) ->
    for key, schema of properties
      @compile_references schema, context.child(key)
  
  items_refs: (definition, context) ->
    if @test_type "array", definition
      for def, i in definition
        @compile_references def, context.child(i.toString())
    else
      @compile_references definition, context


  compile: (schema, context) ->
    {scope, pointer} = context
    tests = []

    if uri = schema.$ref
      uri = URI.resolve(scope, uri)
      if pointer.indexOf(uri) == 0
        return @handle_recursion(schema, context)
      schema = @find(uri)
      if !schema
        throw new Error "No schema found for $ref '#{uri}'"

    if extended = schema.extends
      if ref = extended.$ref
        uri = URI.resolve(scope, ref)
        extended = @find(uri)
        if !extended
          throw new Error "No schema found for $ref '#{ref}'"

      delete schema.extends
      if @test_type "array", extended
        deap.merge(schema, extended...)
      else
        deap.merge(schema, extended)


    for attribute, definition of schema
      if spec = @attributes[attribute]
        if !spec.ignore
          new_context = context.child(attribute)
          new_context.modifiers = {}
          if spec.modifiers
            for key in spec.modifiers
              new_context.modifiers[key] = schema[key]

          # Delegate to a handler named after the attribute
          test = @[attribute](definition, new_context)
          test.pointer = new_context.pointer
          tests.push test
      else
        if @test_type "object", definition
          @compile definition, context.child(attribute)
        else
          console.log "Unknown attribute: '#{attribute}' is not an object"

    test_function = (data) =>
      for test in tests
        if !test(data)
          return false
      true

    if schema.id && schema.id.indexOf("#") == 0
      uri = URI.resolve scope, schema.id
      @tests[uri] = test_function
    @tests[pointer] = test_function
    test_function


  handle_recursion: (schema, {scope, pointer}) ->
    uri = URI.resolve(scope, schema.$ref)
    if !@find(uri)
      throw new Error "No schema found for $ref '#{uri}'"
    (data) =>
      @tests[uri](data)

  attributes:
    $schema: {ignore: true}
    id: {ignore: true}
    $ref: { ignore: true }
    extends: {ignore: true}

    title: {ignore: true}
    description: {ignore: true}
    default: {ignore: true}

    type: {}
    enum: {}
    disallow: {}

    properties: {}
    required: {ignore: true}
    dependencies: {}
    patternProperties: {}
    additionalProperties:
      modifiers: [
        "properties"
        "patternProperties"
      ]

    items:
      modifiers: [
        "additionalItems"
      ]
    additionalItems: {ignore: true}
    maxItems: {}
    minItems: {}
    uniqueItems: {}


    minimum:
      modifiers: [
        "exclusiveMinimum"
      ]
    exclusiveMinimum: {ignore: true}
    maximum:
      modifiers: [
        "exclusiveMaximum"
      ]
    exclusiveMaximum: {ignore: true}
    divisibleBy: {}

    maxLength: {}
    minLength: {}
    pattern: {}
    format: {}


modules = [
  "type"
  "numeric"
  "comparison"
  "arrays"
  "objects"
  "strings"
]

for module_name in modules
  m = require "./draft3/#{module_name}"
  for name, method of m
    Validator.prototype[name] = method

