require "const"

local function calculate_orientation (self, ori)

   local FrameTime = dmz.time.frame_time ()

   local result = dmz.matrix.new ()

   local dir = ori:transform (const.Forward)
   dir:set_y (0)

   if not dir:is_zero () then
      dir = dir:normalize ()
      local heading = const.Forward:get_angle (dir)
      local cross =  const.Forward:cross (dir)
      if cross:get_y () < 0 then heading = dmz.math.TwoPi - heading end
      local remainder = math.fmod (heading, dmz.math.HalfPi)
      if remainder > (dmz.math.HalfPi / 2) then
         heading = heading + dmz.math.HalfPi - remainder
      else
         heading = heading - remainder
      end

      if dmz.math.is_zero (self.turn) then self.lastTurn = FrameTime - 0.8
      elseif (FrameTime - self.lastTurn) > 0.75 then
         if self.turn > 0.1 then
            heading = heading - dmz.math.HalfPi
            self.lastTurn = FrameTime
         elseif self.turn < -0.1 then
            heading = heading + dmz.math.HalfPi
            self.lastTurn = FrameTime
         else self.lastTurn = FrameTime - 0.6
         end
      end
      result:from_axis_and_angle (const.Up, heading)
   end

   return result
end

local function set_throttle (self, hil)
   if not hil then hil = dmz.object.hil () end
   if hil then
      local throttle = 1
      if (self.speed < self.NormalSpeed) and (self.MinSpeed > 0) then
         throttle = throttle -
            (((self.NormalSpeed - self.speed) / (self.NormalSpeed - self.MinSpeed)) * 0.4)
      elseif self.speed > self.NormalSpeed then
         throttle = throttle +
            (((self.speed - self.NormalSpeed) / (self.MaxSpeed - self.NormalSpeed)) * 0.6)
      end
      dmz.object.scalar (hil, self.throttleHandle, throttle)
   end
end

local function update_time_slice (self, time)

   local hil = dmz.object.hil ()

   if hil and self.active > 0 then

      local state = dmz.object.state (hil)

      if state and state:contains (const.EngineOn) then

         self.wasAlive = true

         local pos = dmz.object.position (hil)
         local vel = dmz.object.velocity (hil)
         local ori = dmz.object.orientation (hil)

         if not pos then pos = dmz.vector.new () end
         if not vel then vel = dmz.vector.new () end
         if not ori then ori = dmz.matrix.new () end

         ori = calculate_orientation (self, ori)

         local dir = ori:transform (dmz.vector.forward ())

         if self.accel > 0.1 then
            self.speed = self.speed + (self.Deceleration * time)
            if self.speed < self.MinSpeed then self.speed = self.MinSpeed end
         elseif self.accel < -0.1 then
            self.speed = self.speed + (self.Acceleration * time)
            if self.speed > self.MaxSpeed then self.speed = self.MaxSpeed end
         end

         set_throttle (self, hil)

         vel = dir * (self.speed)
         local origPos = pos
         pos = pos + (vel * time)

         local passed =
            ((self.speed > 0) and const.test_move (self, hil, origPos, pos, ori) or true)

         dmz.object.position (hil, nil, (passed and pos or origPos))
         dmz.object.velocity (hil, nil, (passed and vel or {0, 0, 0}))
         dmz.object.orientation (hil, nil, ori)
      elseif self.wasAlive and state and
            (state:contains (const.Dead) or state:contains (const.Standby)) then
         self.wasAlive = nil
         local ori = dmz.object.orientation (hil)
         if not ori then ori = dmz.matrix.new () end
         local dir = ori:transform (dmz.vector.forward ())
         self.speed = self.NormalSpeed
         dmz.object.velocity (hil, nil, dir * self.speed)
      end
   end
end

local function update_channel_state (self, channel, state)

   if state then  self.active = self.active + 1
   else self.active = self.active - 1 end

   if self.active == 1 then self.timeSlice:start (self.handle)
   elseif self.active == 0 then
      self.timeSlice:stop (self.handle)
      local hil = dmz.object.hil ()
      if hil then dmz.object.scalar (hil, self.throttleHandle, 0) end
   end
end

local function receive_axis_event (self, channel, axis)
   local value = 0
   if not dmz.math.is_zero (axis.value, 0.1) then
      if axis.value > 0 then value = 1
      else value = -1
      end
   end
   if axis.which == 2 then --self.speed = value * self.moveSpeed
   elseif axis.which == 1 then self.turn = value
   elseif axis.which == 6 then --self.strafe = value * self.moveSpeed
   elseif axis.which == 7 then self.accel = value
   end
end

local function start (self)
   self.handle = self.timeSlice:create (update_time_slice, self, self.name)

   self.inputObs:register (
      self.config,
      {
         update_channel_state = update_channel_state,
         receive_axis_event = receive_axis_event,
      },
      self);

   if self.handle and self.active == 0 then self.timeSlice:stop (self.handle) end
end


local function stop (self)
   if self.handle and self.timeSlice then self.timeSlice:destroy (self.handle) end
   self.inputObs:release_all ()
end


function new (config, name)
   local self = {
      throttleHandle = dmz.handle.new (
         config:to_string ("throttle.name", "throttle")),
      Acceleration = config:to_number ("speed.acceleration", 10),
      Deceleration = config:to_number ("speed.deceleration", -10),
      MinSpeed = config:to_number ("speed.min", 27.78),
      NormalSpeed = config:to_number ("speed.normal", 41.67),
      MaxSpeed = config:to_number ("speed.max", 55.56),
      turn = 0,
      speed = 0,
      accel = 0,
      lastTurn = dmz.time.frame_time (),
      start_plugin = start,
      stop_plugin = stop,
      name = name,
      log = dmz.log.new ("lua." .. name),
      timeSlice = dmz.time_slice.new (),
      inputObs = dmz.input_observer.new (),
      active = 0,
      config = config,
   }

   self.speed = self.NormalSpeed

   if self.MinSpeed > self.MaxSpeed then
      self.log:warn ("Max Speed is less than Minimum Speed")
      self.MaxSpeed = self.MinSpeed
   end

   if self.Acceleration < 0 then self.Acceleration = -self.Acceleration end
   if self.Deceleration > 0 then self.Deceleration = -self.Deceleration end
      
   self.log:info ("Creating plugin: " .. name)
   
   return self
end

