# Plugin that tracks Heavy TM state for Dragon's Breath and spits when ready.
class Spit
  def initialize()
    @enabled = DRStats.guild == "Warrior Mage"
    return unless @enabled

    Flags.add("spit", /You feel ready for more firebreathing/, /A halo of fire flickers into being/)
    Flags["spit"] = DRSpells.active_spells.to_s.match("Dragon's Breath")
  end

  def after_initialize(_trainer)
    DRC.message("[spit] loaded") if @enabled
  end

  def combat_tick(_trainer, _game_state, counter:)
    return unless @enabled

    if Flags["spit"]
      DRC.bput('spit', /^You sharply inhale, drawing upon the power of your internalized fire/, /^Your throat is too sore/, /^You spit on the ground/)
      Flags.reset("spit")
    end
  end

  def cleanup(_trainer)
    Flags.delete("spit") if @enabled
  end
end

CombatTrainer.register_plugin(Spit.new())
