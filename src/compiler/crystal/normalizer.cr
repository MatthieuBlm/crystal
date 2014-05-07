require "program"
require "transformer"
require "set"

module Crystal
  class Program
    def normalize(node)
      normalizer = Normalizer.new(self)
      node = normalizer.normalize(node)
      puts node if ENV["SSA"] == "1"
      node
    end
  end

  class Normalizer < Transformer
    getter program

    def initialize(@program)
      @dead_code = false
    end

    def normalize(node)
      node.transform(self)
    end

    def before_transform(node)
      @dead_code = false
    end

    def after_transform(node)
      case node
      when Return, Break, Next
        @dead_code = true
      when If, Case, Unless, And, Or, Expressions, Block
       # Skip
      else
        @dead_code = false
      end
    end

    def transform(node : Expressions)
      exps = [] of ASTNode
      node.expressions.each do |exp|
        new_exp = exp.transform(self)
        if new_exp
          if new_exp.is_a?(Expressions)
            exps.concat new_exp.expressions
          else
            exps << new_exp
          end
        end
        break if @dead_code
      end
      case exps.length
      when 0
        Nop.new
      when 1
        exps[0]
      else
        node.expressions = exps
        node
      end
    end

    # Convert and to if:
    #
    # From:
    #
    #     a && b
    #
    # To:
    #
    #     if temp = a
    #       b
    #     else
    #       temp
    #     end
    def transform(node : And)
      left = node.left
      new_node = if left.is_a?(Var) || (left.is_a?(IsA) && left.obj.is_a?(Var))
               If.new(left, node.right, left.clone)
             elsif left.is_a?(Assign) && left.target.is_a?(Var)
               If.new(left, node.right, left.target.clone)
             else
               temp_var = new_temp_var
               If.new(Assign.new(temp_var.clone, left), node.right, temp_var.clone)
             end
      new_node.binary = :and
      new_node.location = node.location
      new_node.transform(self)
    end

    # Convert or to if
    #
    # From:
    #
    #     a || b
    #
    # To:
    #
    #     if temp = a
    #       temp
    #     else
    #       b
    #     end
    def transform(node : Or)
      left = node.left
      new_node = if left.is_a?(Var)
                   If.new(left, left.clone, node.right)
                 elsif left.is_a?(Assign) && left.target.is_a?(Var)
                   If.new(left, left.target.clone, node.right)
                 else
                   temp_var = new_temp_var
                   If.new(Assign.new(temp_var.clone, left), temp_var.clone, node.right)
                 end
      new_node.binary = :or
      new_node.location = node.location
      new_node.transform(self)
    end

    # Store regex in a constant and replace the regex by this constant
    # (so we don't create an object each time).
    #
    # From:
    #
    #     /regex/
    #
    # To:
    #
    #     ::CONST = /regex/
    #     CONST
    def transform(node : RegexLiteral)
      const_name = "#Regex_#{node.value}_#{node.modifiers}"
      unless program.types[const_name]?
        constructor = Call.new(Path.new(["Regex"], true), "new", [StringLiteral.new(node.value), NumberLiteral.new(node.modifiers, :i32)] of ASTNode)
        program.types[const_name] = const = Const.new program, program, const_name, constructor, [program] of Type, program
        @program.regexes << const
      end

      path = Path.new([const_name], true)
      path.location = node.location
      path
    end

    # Convert an interpolation to a concatenation with a StringBuilder:
    #
    # From:
    #
    #     "foo#{bar}baz"
    #
    # To:
    #
    #     (StringBuilder.new << "foo" << bar << "baz").to_s
    def transform(node : StringInterpolation)
      super

      call = Call.new(Path.new(["StringBuilder"], true), "new")
      node.expressions.each do |piece|
        call = Call.new(call, "<<", [piece])
      end
      call = Call.new(call, "to_s")
      call.location = node.location
      call
    end

    # Transform a range literal into creating a Range object.
    #
    # From:
    #
    #    1 .. 3
    #
    # To:
    #
    #    Range.new(1, 3, true)
    #
    # From:
    #
    #    1 ... 3
    #
    # To:
    #
    #    Range.new(1, 3, false)
    def transform(node : RangeLiteral)
      super

      Call.new(Path.new(["Range"], true), "new", [node.from, node.to, BoolLiteral.new(node.exclusive)])
    end

    # Convert an array literal to creating an Array and storing the values:
    #
    # From:
    #
    #     [] of T
    #
    # To:
    #
    #     Array(T).new
    #
    # From:
    #
    #     [1, 2, 3]
    #
    # To:
    #
    #     ary = Array(typeof(1, 2, 3)).new(3)
    #     ary.length = 3
    #     buffer = ary.buffer
    #     buffer[0] = 1
    #     buffer[1] = 2
    #     buffer[2] = 3
    #     ary
    def transform(node : ArrayLiteral)
      super

      if node_of = node.of
        if node.elements.length == 0
          generic = Generic.new(Path.new(["Array"], true), [node_of] of ASTNode)
          generic.location = node.location

          call = Call.new(generic, "new")
          call.location = node.location
          return call
        end

        type_var = node_of
      else
        type_var = TypeOf.new(node.elements)
      end

      length = node.elements.length
      capacity = length

      generic = Generic.new(Path.new(["Array"], true), [type_var] of ASTNode)
      generic.location = node.location

      constructor = Call.new(generic, "new", [NumberLiteral.new(capacity, :i32)] of ASTNode)
      constructor.location = node.location

      temp_var = new_temp_var
      assign = Assign.new(temp_var.clone, constructor)
      assign.location = node.location

      set_length = Call.new(temp_var.clone, "length=", [NumberLiteral.new(length, :i32)] of ASTNode)
      set_length.location = node.location

      get_buffer = Call.new(temp_var.clone, "buffer")
      get_buffer.location = node.location

      buffer = new_temp_var
      buffer.location = node.location

      assign_buffer = Assign.new(buffer.clone, get_buffer)
      assign_buffer.location = node.location

      exps = [assign, set_length, assign_buffer] of ASTNode

      node.elements.each_with_index do |elem, i|
        assign_index = Call.new(buffer.clone, "[]=", [NumberLiteral.new(i, :i32), elem] of ASTNode)
        assign_index.location = node.location

        exps << assign_index
      end

      exps << temp_var.clone

      exps = Expressions.new(exps)
      exps.location = node.location
      exps
    end

    # Convert a HashLiteral into creating a Hash and assigning keys and values:
    #
    # From:
    #
    #     {} of K => V
    #
    # To:
    #
    #     Hash(K, V).new
    #
    # From:
    #
    #     {a => b, c => d}
    #
    # To:
    #
    #     hash = Hash(typeof(a, c), typeof(b, d)).new
    #     hash[a] = b
    #     hash[c] = d
    #     hash
    def transform(node : HashLiteral)
      super

      if (node_of_key = node.of_key)
        node_of_value = node.of_value
        raise "Bug: node.of_value shouldn't be nil if node.of_key is not nil" unless node_of_value

        type_vars = [node_of_key, node_of_value] of ASTNode
      else
        type_vars = [TypeOf.new(node.keys), TypeOf.new(node.values)] of ASTNode
      end

      constructor = Call.new(Generic.new(Path.new(["Hash"], true), type_vars), "new")
      if node.keys.length == 0
        constructor.location = node.location
        constructor
      else
        temp_var = new_temp_var
        assign = Assign.new(temp_var.clone, constructor)

        exps = [assign] of ASTNode
        node.keys.each_with_index do |key, i|
          exps << Call.new(temp_var.clone, "[]=", [key, node.values[i]])
        end
        exps << temp_var.clone
        exp = Expressions.new exps
        exp.location = node.location
        exp
      end
    end

    # Transform a multi assign into many assigns.
    def transform(node : MultiAssign)
      # From:
      #
      #     a, b = 1
      #
      #
      # To:
      #
      #     temp = 1
      #     a = temp
      #     b = temp
      if node.values.length == 1
        value = node.values[0]

        temp_var = new_temp_var

        assigns = [] of ASTNode

        assign = Assign.new(temp_var.clone, value)
        assign.location = value.location
        assigns << assign

        node.targets.each_with_index do |target, i|
          call = Call.new(temp_var.clone, "[]", [NumberLiteral.new(i, :i32)] of ASTNode)
          call.location = value.location
          assigns << transform_multi_assign_target(target, call)
        end
        exps = Expressions.new(assigns)

      # From:
      #
      #     a = 1, 2, 3
      #
      # To:
      #
      #     a = [1, 2, 3]
      elsif node.targets.length == 1
        target = node.targets.first
        array = ArrayLiteral.new(node.values)
        exps = transform_multi_assign_target(target, array)

      # From:
      #
      #     a, b = c, d
      #
      # To:
      #
      #     temp1 = c
      #     temp2 = d
      #     a = temp1
      #     b = temp2
      else
        temp_vars = node.values.map { new_temp_var }

        assign_to_temps = [] of ASTNode
        assign_from_temps = [] of ASTNode

        temp_vars.each_with_index do |temp_var_2, i|
          assign = Assign.new(temp_var_2.clone, node.values[i])
          assign.location = node.location
          assign_to_temps << assign
          assign_from_temps << transform_multi_assign_target(node.targets[i], temp_var_2.clone)
        end

        exps = Expressions.new(assign_to_temps + assign_from_temps)
      end
      exps.location = node.location
      exps.transform(self)
    end

    def transform_multi_assign_target(target, value)
      if target.is_a?(Call)
        target.name = "#{target.name}="
        target.args << value
        target
      else
        assign = Assign.new(target, value)
        assign.location = target.location
        assign
      end
    end

    def transform(node : Call)
      # Convert 'a <= b <= c' to 'a <= b && b <= c'
      if comparison?(node.name) && (obj = node.obj) && obj.is_a?(Call) && comparison?(obj.name)
        case middle = obj.args.first
        when NumberLiteral, Var, InstanceVar
          transform_many node.args
          left = obj
          right = Call.new(middle, node.name, node.args)
        else
          temp_var = new_temp_var
          temp_assign = Assign.new(temp_var.clone, middle)
          left = Call.new(obj.obj, obj.name, [temp_assign] of ASTNode)
          right = Call.new(temp_var.clone, node.name, node.args)
        end
        node = And.new(left, right)
        node = node.transform self
      else
        node = super
      end

      node
    end

    def comparison?(name)
      case name
      when "<=", "<", "!=", "==", "===", ">", ">="
        true
      else
        false
      end
    end

    # Expand a def with default arguments into many defs:
    #
    # From:
    #
    #   def foo(x, y = 1, z = 2)
    #     ...
    #   end
    #
    # To:
    #
    #   def foo(x)
    #     foo(x, 1)
    #   end
    #
    #   def foo(x, y)
    #     foo(x, y, 2)
    #   end
    #
    #   def foo(x, y, z)
    #     ...
    #   end
    def transform(node : Def)
      if node.has_default_arguments?
        exps = [] of ASTNode
        node.expand_default_arguments.each do |exp|
          exps << exp.transform(self)
        end
        return Expressions.new(exps)
      end

      super
    end

    def transform(node : Macro)
      node
    end

    # Convert a Case into a series of if ... elseif ... end:
    #
    # From:
    #
    #     case foo
    #     when bar, baz
    #       1
    #     when bun
    #       2
    #     else
    #       3
    #     end
    #
    # To:
    #
    #     temp = foo
    #     if bar === temp || baz === temp
    #       1
    #     elsif bun === temp
    #       2
    #     else
    #       3
    #     end
    #
    # But, when the "when" has a constant name, it's transformed to is_a?:
    #
    # From:
    #
    #     case foo
    #     when Bar
    #       1
    #     end
    #
    # To:
    #
    #     temp = foo
    #     if temp.is_a?(Bar)
    #       1
    #     end
    def transform(node : Case)
      node.cond = node.cond.try &.transform(self)

      node_cond = node.cond
      if node_cond
        case node_cond
        when Var, InstanceVar
          temp_var = node.cond
        when Assign
          temp_var = node_cond.target
          assign = node_cond
        else
          temp_var = new_temp_var
          assign = Assign.new(temp_var.clone, node_cond)
        end
      end

      a_if = nil
      final_if = nil
      node.whens.each do |wh|
        final_comp = nil
        wh.conds.each do |cond|
          if temp_var
            right_side = temp_var.clone
            if cond.is_a?(Path) || cond.is_a?(Generic)
              comp = IsA.new(right_side, cond)
            elsif cond.is_a?(Call) && cond.obj.is_a?(ImplicitObj)
              implicit_call = cond.clone as Call
              implicit_call.obj = temp_var.clone
              comp = implicit_call
            else
              comp = Call.new(cond, "===", [right_side] of ASTNode)
            end
          else
            comp = cond
          end

          if final_comp
            final_comp = SimpleOr.new(final_comp, comp)
          else
            final_comp = comp
          end
        end

        wh_if = If.new(final_comp.not_nil!, wh.body)
        if a_if
          a_if.else = wh_if
        else
          final_if = wh_if
        end
        a_if = wh_if
      end

      if node_else = node.else
        a_if.not_nil!.else = node_else
      end

      final_if = final_if.not_nil!.transform(self)
      final_exp = if assign
                    Expressions.new([assign, final_if] of ASTNode)
                  else
                    final_if
                  end
      final_exp.location = node.location
      final_exp
    end

    def transform(node : If)
      node.cond = node.cond.transform(self)

      node.then = node.then.transform(self)
      then_dead_code = @dead_code

      node.else = node.else.transform(self)
      else_dead_code = @dead_code

      @dead_code = then_dead_code &&  else_dead_code
      node
    end

    # Convert unless to if:
    #
    # From:
    #
    #     unless foo
    #       bar
    #     else
    #       baz
    #     end
    #
    # To:
    #
    #     if foo
    #       baz
    #     else
    #       bar
    #     end
    def transform(node : Unless)
      a_if = If.new(node.cond, node.else, node.then).transform(self)
      a_if.location = node.location
      a_if
    end

    # Evaluate the ifdef's flags.
    # If they hold, keep the "then" part.
    # If they don't, keep the "else" part.
    def transform(node : IfDef)
      cond_value = eval_flags(node.cond)
      if cond_value
        node.then.transform(self)
      else
        node.else.transform(self)
      end
    end

    # Transform require to its source code.
    # The source code can be a Nop if the file was already required.
    def transform(node : Require)
      location = node.location
      required = @program.require(node.string, location.try &.filename).not_nil!
      required.transform(self)
    rescue ex : Crystal::Exception
      node.raise "while requiring \"#{node.string}\"", ex
    rescue ex
      node.raise "while requiring \"#{node.string}\": #{ex.message}"
    end

    def eval_flags(node)
      evaluator = FlagsEvaluator.new(@program)
      node.accept evaluator
      evaluator.value
    end

    class FlagsEvaluator < Visitor
      getter value

      def initialize(@program)
        @value = false
      end

      def visit(node : ASTNode)
        raise "Bug: shouldn't visit #{node} in FlagsEvaluator"
      end

      def visit(node : Var)
        @value = @program.has_flag?(node.name)
      end

      def visit(node : Not)
        node.exp.accept self
        @value = !@value
        false
      end

      def visit(node : And)
        node.left.accept self
        left_value = @value
        node.right.accept self
        @value = left_value && @value
        false
      end

      def visit(node : Or)
        node.left.accept self
        left_value = @value
        node.right.accept self
        @value = left_value || @value
        false
      end
    end

    def new_temp_var
      program.new_temp_var
    end
  end
end
