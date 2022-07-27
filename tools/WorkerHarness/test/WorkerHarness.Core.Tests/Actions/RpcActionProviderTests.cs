﻿// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the MIT License. See License.txt in the project root for license information.

// Copyright (c) .NET Foundation. All rights reserved.
// Licensed under the MIT License. See License.txt in the project root for license information.

using Microsoft.Azure.Functions.WorkerHarness.Grpc.Messages;
using Microsoft.Extensions.Logging;
using Moq;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using WorkerHarness.Core.Actions;
using WorkerHarness.Core.GrpcService;
using WorkerHarness.Core.Matching;
using WorkerHarness.Core.StreamingMessageService;
using WorkerHarness.Core.Validators;

namespace WorkerHarness.Core.Tests.Actions
{
    [TestClass]
    public class RpcActionProviderTests
    {
        [TestMethod]
        public void Create_ActionNodeHasNoMessagesProperty_ThrowArgmentException()
        {
            // Arrange
            Channel<StreamingMessage> InboundChannel = Channel.CreateUnbounded<StreamingMessage>();
            Channel<StreamingMessage> OutboundChannel = Channel.CreateUnbounded<StreamingMessage>();
            ILoggerFactory loggerFactory = new LoggerFactory();

            RpcActionProvider provider = new(
                new Mock<IValidatorFactory>().Object,
                new Mock<IMessageMatcher>().Object,
                new Mock<IStreamingMessageProvider>().Object,
                new GrpcServiceChannel(InboundChannel, OutboundChannel),
                loggerFactory
            );

            JsonNode actionNode = new JsonObject();

            // Act
            try
            {
                provider.Create(actionNode);
            }
            // Assert
            catch (ArgumentException ex)
            {
                Assert.AreEqual(RpcActionProvider.ArgumentMissingMessagesProperty, ex.Message);
                return;
            }

            Assert.Fail($"The expected {typeof(ArgumentException)} is not thrown");
        }

        [TestMethod]
        public void Create_ActionNodeHasInvalidMessages_ThrowArgumentException()
        {
            // Arrange
            Channel<StreamingMessage> InboundChannel = Channel.CreateUnbounded<StreamingMessage>();
            Channel<StreamingMessage> OutboundChannel = Channel.CreateUnbounded<StreamingMessage>();
            ILoggerFactory loggerFactory = new LoggerFactory();

            RpcActionProvider provider = new(
                new Mock<IValidatorFactory>().Object,
                new Mock<IMessageMatcher>().Object,
                new Mock<IStreamingMessageProvider>().Object,
                new GrpcServiceChannel(InboundChannel, OutboundChannel),
                loggerFactory
            );

            JsonNode actionNode = new JsonObject
            {
                ["messages"] = new JsonObject()
            };

            // Act
            try
            {
                provider.Create(actionNode);
            }
            // Assert
            catch (ArgumentException ex)
            {
                Assert.AreEqual(RpcActionProvider.ArgumentMissingMessagesProperty, ex.Message);
                return;
            }

            Assert.Fail($"The expected {typeof(ArgumentException)} is not thrown");
        }

        [TestMethod]
        public void Create_ActionNodeIsValid_ReturnRpcAction()
        {
            // Arrange
            Channel<StreamingMessage> InboundChannel = Channel.CreateUnbounded<StreamingMessage>();
            Channel<StreamingMessage> OutboundChannel = Channel.CreateUnbounded<StreamingMessage>();
            ILoggerFactory loggerFactory = new LoggerFactory();

            RpcActionProvider provider = new(
                new Mock<IValidatorFactory>().Object,
                new Mock<IMessageMatcher>().Object,
                new Mock<IStreamingMessageProvider>().Object,
                new GrpcServiceChannel(InboundChannel, OutboundChannel),
                loggerFactory
            );

            JsonNode actionNode = new JsonObject
            {
                ["actionName"] = "test",
                ["timeout"] = 5000,
                ["messages"] = new JsonArray(
                    new JsonObject(),
                    new JsonObject()
                )
            };

            // Act
            IAction action = provider.Create(actionNode);

            // Assert
            Assert.IsTrue(action is RpcAction);
            RpcAction rpcAction = (RpcAction)action;
            Assert.AreEqual("test", rpcAction.Name);
            Assert.AreEqual(5000, rpcAction.Timeout);
            Assert.AreEqual(ActionTypes.Rpc, rpcAction.Type);
        }
    }
}